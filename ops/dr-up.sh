#!/usr/bin/env bash
# =============================================================================
# dr-up.sh - rebuild the whole n8n platform on a NEW, EMPTY Kubernetes cluster
#            from this git repo + your backups (age-encrypted keys on Google
#            Drive, Postgres PITR archive in S3).
#
#   ./ops/dr-up.sh preflight   checks only, changes nothing
#   ./ops/dr-up.sh clean       remove leftovers of an earlier (failed) run
#   ./ops/dr-up.sh             preflight -> build -> post-DR checks   (DRILL)
#   ./ops/dr-up.sh --real      same, but the new cluster keeps archiving to S3
#                              (use only when the old cluster is really gone)
#   ./ops/dr-up.sh verify      post-DR checks only
#
# Needs two files; by default they are looked up next to the repo folder
# (e.g. ~/n8n/age-key.txt and ~/n8n/rclone.conf):
#   AGE_IDENTITY=/path/age-key.txt   RCLONE_CONFIG=/path/rclone.conf
#
# Options : --yes (no prompt)   --fresh-db (delete the restored DB and redo it)
# Env     : TARGET_TIME=2026-10-29T08:00:00Z   restore to this moment (PITR)
#           SOURCE_SERVER=n8n-db               S3 folder to restore from
#           BACKUP_DATE=YYYYMMDD               key backup to use (default newest)
#           START_N8N=0                        stop after DB + Redis (n8n off)
#           MONITORING_VALUES / ALERTMANAGER_VALUES   extra helm values files
# Tip     : ./ops/dr-up.sh 2>&1 | tee ~/n8n/dr.log     keeps a log to share
# Safe to re-run: every step checks what already exists.
# =============================================================================
set -Eeuo pipefail

# ------------------------------- settings ------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT="$(cd "$REPO/.." && pwd)"
MODE="${DR_MODE:-drill}"
AGE_IDENTITY="${AGE_IDENTITY:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
if [[ -z "$AGE_IDENTITY" && -r "$PARENT/age-key.txt" ]]; then AGE_IDENTITY="$PARENT/age-key.txt"; fi
if [[ -z "$RCLONE_CONFIG" && -r "$PARENT/rclone.conf" ]]; then RCLONE_CONFIG="$PARENT/rclone.conf"; fi
if [[ -n "$RCLONE_CONFIG" ]]; then export RCLONE_CONFIG; fi
GDRIVE="${GDRIVE_PATH:-gdrive:n8n-dr}"
BACKUP_DATE="${BACKUP_DATE:-latest}"
SOURCE_SERVER="${SOURCE_SERVER:-}"
TARGET_TIME="${TARGET_TIME:-}"
START_N8N="${START_N8N:-1}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-2400}"
MONITORING_VALUES="${MONITORING_VALUES:-}"
ALERTMANAGER_VALUES="${ALERTMANAGER_VALUES:-}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"
ASSUME_YES=0
FRESH_DB=0
NEW_SERVER=""
LEFT=0

N8N_NS=n8n
REDIS_NS=redis-ha
SECRET_NAME=n8n-secrets
PLUGIN=barman-cloud.cloudnative-pg.io
NS_LIST=(argocd n8n redis-ha cnpg-system cert-manager keda vpa monitoring)
CRD_RE='\.(argoproj\.io|cnpg\.io|cert-manager\.io|keda\.sh|autoscaling\.k8s\.io|monitoring\.coreos\.com)$|^sealedsecrets\.bitnami\.com$'
CLUSTER_RE='argocd|cnpg|cloudnative-pg|cert-manager|keda|vpa|prometheus|sealed-secrets|secrets-unsealer|barman|external\.metrics\.k8s\.io'

CMD=up
for a in "$@"; do
  case "$a" in
    up|preflight|clean|verify) CMD=$a ;;
    --real) MODE=real ;;
    --drill) MODE=drill ;;
    --yes|-y) ASSUME_YES=1 ;;
    --fresh-db) FRESH_DB=1 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)"; exit 2 ;;
  esac
done
[[ "$MODE" == drill || "$MODE" == real ]] || { echo "DR_MODE must be drill or real"; exit 2; }

# ------------------------------- helpers -------------------------------------
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else R=; G=; Y=; B=; N=; fi
PASS=0; WARN=0; FAIL=0; PF_PID=""
ok()   { echo "  ${G}PASS${N}  $*"; PASS=$((PASS+1)); }
warn() { echo "  ${Y}WARN${N}  $*"; WARN=$((WARN+1)); }
bad()  { echo "  ${R}FAIL${N}  $*"; FAIL=$((FAIL+1)); }
log()  { echo "        $*"; }
step() { echo; echo "${B}==> $*${N}"; }
die()  { echo "${R}ERROR:${N} $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

umask 077
TMP="$(mktemp -d)"
pf_stop() { if [[ -n "$PF_PID" ]]; then kill "$PF_PID" >/dev/null 2>&1 || true; fi; PF_PID=""; }
cleanup() { pf_stop; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'echo "${R}ERROR:${N} failed at line $LINENO. Fix the cause and re-run; finished steps are skipped." >&2' ERR

# retry <tries> <sleep> <cmd...>
retry() { local n=$1 s=$2 i; shift 2; for ((i=1; i<=n; i++)); do if "$@"; then return 0; fi; sleep "$s"; done; return 1; }
# wait_until <seconds> <what> <cmd...>   (polls every 5s, returns 1 on timeout)
wait_until() {
  local t=$1 what=$2; shift 2; local end=$((SECONDS+t))
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= end )); then echo "timed out waiting for: $what" >&2; return 1; fi
    sleep 5
  done
}
wait_crd() { wait_until 900 "CRD $1" kubectl get crd "$1" || die "CRD $1 never appeared"; kubectl wait --for=condition=Established "crd/$1" --timeout=180s >/dev/null; }

app_ok() { kubectl -n argocd get application "$1" -o json 2>/dev/null | jq -e '.status.sync.status=="Synced" and .status.health.status=="Healthy"' >/dev/null 2>&1; }
# wait until the Argo apps are Synced+Healthy; kick a sync every ~2 min if one is stuck
wait_apps() {
  local t=$1; shift; local end=$((SECONDS+t)) kick=$SECONDS a pending
  while :; do
    pending=(); for a in "$@"; do if ! app_ok "$a"; then pending+=("$a"); fi; done
    if (( ${#pending[@]} == 0 )); then return 0; fi
    if (( SECONDS >= end )); then echo "Argo apps not ready: ${pending[*]}" >&2; return 1; fi
    if (( SECONDS - kick > 120 )); then
      for a in "${pending[@]}"; do kubectl -n argocd patch application "$a" --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true; done
      kick=$SECONDS
    fi
    log "waiting for Argo apps: ${pending[*]}"; sleep 15
  done
}
app_name() { awk '/^  name:/{print $2; exit}' "$1"; }
app_file() { local f; for f in "$REPO"/argocd/apps/*.yaml; do if [[ "$(app_name "$f")" == "$1" ]]; then echo "$f"; return 0; fi; done; return 1; }
# YAML file -> one compact JSON object per line (needs the CRDs to be installed)
y2j() { kubectl create --dry-run=client --validate=false -o json -f "$1" | jq -c 'if .kind=="List" then .items[] else . end'; }
# first file in deploy/base that holds a given kind
file_of() { { grep -lE "^kind: $1[[:space:]]*\$" "$REPO"/deploy/base/*.yaml 2>/dev/null || true; } | sed -n 1p; }

pf_start() { kubectl -n "$1" port-forward "$2" "$3:$4" >/dev/null 2>&1 & PF_PID=$!; sleep 4; }

to_mib()   { awk -v v="$1" 'BEGIN{ if(v~/Ki$/){sub(/Ki$/,"",v);print int(v/1024)} else if(v~/Mi$/){sub(/Mi$/,"",v);print int(v)} else if(v~/Gi$/){sub(/Gi$/,"",v);print int(v*1024)} else print int(v/1048576) }'; }
to_cores() { awk -v v="$1" 'BEGIN{ if(v~/m$/){sub(/m$/,"",v);print v/1000} else print v+0 }'; }
slug()     { echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-50; }

confirm() {
  local ctx a; ctx=$(kubectl config current-context)
  echo; echo "  kubectl context : ${B}$ctx${N}"
  echo "  nodes           : $(kubectl get nodes -o name 2>/dev/null | sed 's#node/##' | paste -sd' ')"
  echo "  mode            : ${B}$MODE${N}   repo: $REPO @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "  $1"
  if (( ASSUME_YES )); then return 0; fi
  [[ -t 0 ]] || die "not a terminal: re-run with --yes"
  read -r -p "  Type the context name to continue: " a; [[ "$a" == "$ctx" ]] || die "context name did not match, aborting"
  if [[ "$MODE" == real && "$CMD" == up ]]; then read -r -p "  REAL mode: type REAL to confirm: " a; [[ "$a" == REAL ]] || die "aborting"; fi
}

load_versions() {
  local f="$REPO/dr/versions.env" v
  [[ -r "$f" ]] || die "missing $f"
  # shellcheck disable=SC1090
  . "$f"
  for v in ARGOCD_VERSION KPS_VERSION SEALED_SECRETS_VERSION; do
    [[ -n "${!v:-}" && "${!v}" != CHANGE_ME ]] || die "set $v in dr/versions.env"
  done
  [[ "${SEALED_SECRETS_INSTALL:-manifest}" == manifest ]] || die "this script installs Sealed Secrets from the release manifest (SEALED_SECRETS_INSTALL=manifest)"
}

# ----------------------- leftovers of an earlier run -------------------------
# prints what is left and sets LEFT (call it directly, not inside $(...))
leftovers() {
  LEFT=0; local ns x
  for ns in "${NS_LIST[@]}"; do if kubectl get ns "$ns" >/dev/null 2>&1; then echo "namespace/$ns"; LEFT=$((LEFT+1)); fi; done
  x=$(kubectl get crd -o name 2>/dev/null | sed 's#.*/##' | grep -E "$CRD_RE" || true)
  if [[ -n "$x" ]]; then echo "$x" | sed 's#^#crd/#'; LEFT=$((LEFT+$(echo "$x" | wc -l))); fi
  x=$(kubectl get clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration,apiservice -o name 2>/dev/null | grep -E "$CLUSTER_RE" || true)
  if [[ -n "$x" ]]; then echo "$x"; LEFT=$((LEFT+$(echo "$x" | wc -l))); fi
  if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then echo "kube-system/deploy/sealed-secrets-controller"; LEFT=$((LEFT+1)); fi
}

# =============================================================================
#  CLEAN  (best effort; only for a throw-away DR cluster)
# =============================================================================
strip_crs() {  # remove finalizers from every instance of CRD $1 so deletion cannot hang
  local res=$1 ns name
  kubectl get "$res" -A -o json 2>/dev/null | jq -r '.items[] | [(.metadata.namespace // ""), .metadata.name] | @tsv' |
  while IFS=$'\t' read -r ns name; do
    if [[ -n "$ns" ]]; then kubectl -n "$ns" patch "$res" "$name" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    else kubectl patch "$res" "$name" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; fi
  done
}

clean() {
  step "CLEAN: remove what an earlier DR run left in this cluster"
  kubectl get ns >/dev/null 2>&1 || die "cluster not reachable"
  if [[ "$FORCE_CLEAN" != 1 ]] && kubectl -n "$N8N_NS" get cluster.postgresql.cnpg.io -o json 2>/dev/null |
       jq -e '[.items[]|select((.spec.plugins // [])|length>0)]|length>0' >/dev/null 2>&1; then
    die "this cluster's Postgres archives WAL to S3: it looks like PRODUCTION or a --real DR cluster. Refusing. (FORCE_CLEAN=1 to override)"
  fi
  confirm "This DELETES: namespaces ${NS_LIST[*]}, their CRDs, Sealed Secrets and the Argo/CNPG/KEDA/VPA/cert-manager cluster objects."
  local a crd ns n rel crds

  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do kubectl -n argocd patch "$a" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; done
    kubectl -n argocd delete applications --all --wait=false --cascade=orphan >/dev/null 2>&1 || true
  fi
  if has helm; then
    for rel in $(helm list -A -o json 2>/dev/null | jq -r '.[]|select(.name=="prometheus" or .name=="sealed-secrets")|"\(.namespace)/\(.name)"'); do
      log "helm uninstall ${rel#*/} (${rel%/*})"; helm uninstall "${rel#*/}" -n "${rel%/*}" --timeout 2m >/dev/null 2>&1 || true
    done
  fi
  kubectl delete ns "${NS_LIST[@]}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  crds=$(kubectl get crd -o name 2>/dev/null | sed 's#.*/##' | grep -E "$CRD_RE" || true)
  for crd in $crds; do strip_crs "$crd"; done
  if [[ -n "$crds" ]]; then
    # shellcheck disable=SC2086
    kubectl delete crd $crds --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  kubectl -n kube-system delete deploy/sealed-secrets-controller svc/sealed-secrets-controller svc/sealed-secrets-controller-metrics \
    sa/sealed-secrets-controller role/sealed-secrets-service-proxier role/sealed-secrets-key-admin \
    rolebinding/sealed-secrets-service-proxier rolebinding/sealed-secrets-controller --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key --ignore-not-found >/dev/null 2>&1 || true
  kubectl get clusterrole,clusterrolebinding,validatingwebhookconfiguration,mutatingwebhookconfiguration,apiservice -o name 2>/dev/null |
    { grep -E "$CLUSTER_RE" || true; } | xargs -r kubectl delete --ignore-not-found --wait=false >/dev/null 2>&1 || true

  log "waiting for namespaces to disappear (stuck ones are force-finalised after 90s)"
  local t0=$SECONDS
  while (( SECONDS - t0 < 300 )); do
    n=0
    for ns in "${NS_LIST[@]}"; do
      if kubectl get ns "$ns" >/dev/null 2>&1; then
        n=$((n+1))
        if (( SECONDS - t0 > 90 )); then
          kubectl get ns "$ns" -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
        fi
      fi
    done
    if (( n == 0 )); then break; fi
    sleep 10
  done
  # volumes that belonged to the deleted namespaces
  kubectl get pv -o json 2>/dev/null | jq -r --argjson ns "$(printf '%s\n' "${NS_LIST[@]}" | jq -R . | jq -sc .)" \
    '.items[] | select(.spec.claimRef.namespace as $c | $ns | index($c)) | .metadata.name' | xargs -r kubectl delete pv --wait=false >/dev/null 2>&1 || true

  step "what is still there"
  leftovers
  if (( LEFT == 0 )); then echo "  ${G}cluster is clean${N}"; else echo "  ${Y}$LEFT item(s) left (see above): run clean again, or recreate the cluster${N}"; fi
}

# =============================================================================
#  PRE-DR CHECKS  (read-only)
# =============================================================================
preflight() {
  step "PRE-DR CHECKS (read-only)"
  local t f u code d age_days list

  echo " tools and inputs"
  for t in kubectl helm jq age rclone curl git; do if has "$t"; then ok "$t installed"; else bad "$t is missing"; fi; done
  if (( FAIL > 0 )); then die "install the missing tools, then re-run"; fi
  if [[ -r "$AGE_IDENTITY" ]]; then ok "age identity: $AGE_IDENTITY"; else bad "age identity not found (set AGE_IDENTITY=/path/age-key.txt)"; fi
  if [[ -r "$RCLONE_CONFIG" ]]; then ok "rclone config: $RCLONE_CONFIG"; else bad "rclone config not found (set RCLONE_CONFIG=/path/rclone.conf)"; fi
  if (( FAIL > 0 )); then die "fix the inputs above, then re-run"; fi

  echo " repo"
  for f in bootstrap/root.yaml argocd/apps deploy/base dr/versions.env deploy/n8n-values.yaml; do
    if [[ -e "$REPO/$f" ]]; then ok "repo has $f"; else bad "repo is missing $f"; fi
  done
  if [[ -n "$(file_of Cluster)" && -n "$(file_of ObjectStore)" ]]; then ok "repo has a Postgres Cluster and an ObjectStore"; else bad "deploy/base needs a Cluster and an ObjectStore"; fi
  if grep -rqsE 'repoURL: *(git@|ssh://)' "$REPO/argocd/apps" "$REPO/bootstrap"; then bad "an Argo app uses an SSH repo URL; this script only supports https"; fi
  if git -C "$REPO" fetch -q origin main 2>/dev/null; then
    if [[ "$(git -C "$REPO" rev-parse HEAD)" == "$(git -C "$REPO" rev-parse origin/main)" ]]; then ok "checkout equals origin/main (Argo deploys GitHub main)"
    else warn "checkout differs from origin/main: Argo deploys what is on GitHub, not your local files"; fi
  else warn "could not reach GitHub to compare with origin/main"; fi
  if [[ -n "$(git -C "$REPO" status --porcelain deploy argocd bootstrap 2>/dev/null)" ]]; then warn "uncommitted changes in deploy/ argocd/ bootstrap/ are NOT deployed by Argo"; fi
  load_versions
  ok "pinned versions: argocd=$ARGOCD_VERSION kube-prometheus-stack=$KPS_VERSION sealed-secrets=$SEALED_SECRETS_VERSION"

  echo " backups and keys"
  list=$(rclone lsf "$GDRIVE" --files-only 2>/dev/null || true)
  if [[ -n "$list" ]]; then ok "Google Drive reachable ($GDRIVE)"; else bad "cannot list $GDRIVE (rclone remote missing or token expired)"; fi
  if [[ -n "$list" ]]; then
    d="$BACKUP_DATE"
    if [[ "$d" == latest ]]; then
      d=$(comm -12 <(grep -oE '^sealing-keys-[0-9]{8}' <<<"$list" | sed 's/.*-//' | sort -u) \
                   <(grep -oE '^n8n-secrets-[0-9]{8}' <<<"$list" | sed 's/.*-//' | sort -u) | tail -n 1)
    fi
    if [[ "$d" =~ ^[0-9]{8}$ ]] && grep -qx "sealing-keys-$d.json.age" <<<"$list" && grep -qx "n8n-secrets-$d.json.age" <<<"$list"; then
      ok "key backup set dated $d found"
      if rclone copyto "$GDRIVE/sealing-keys-$d.json.age" "$TMP/keys.age" 2>/dev/null && age -d -i "$AGE_IDENTITY" -o "$TMP/keys.json" "$TMP/keys.age" 2>/dev/null &&
         jq -e '.kind=="List" and (.items|length)>0 and all(.items[]; .metadata.namespace=="kube-system" and .data["tls.crt"]!=null and .data["tls.key"]!=null)' "$TMP/keys.json" >/dev/null 2>&1
      then ok "sealing keys decrypt ($(jq '.items|length' "$TMP/keys.json") key(s))"; else bad "cannot download/decrypt a valid sealing-keys backup (wrong age key?)"; fi
      if rclone copyto "$GDRIVE/n8n-secrets-$d.json.age" "$TMP/n8n.age" 2>/dev/null && age -d -i "$AGE_IDENTITY" -o "$TMP/n8n-secrets.json" "$TMP/n8n.age" 2>/dev/null &&
         jq -e '.data.N8N_ENCRYPTION_KEY|length>0' "$TMP/n8n-secrets.json" >/dev/null 2>&1
      then ok "n8n secrets decrypt and contain N8N_ENCRYPTION_KEY"; else bad "cannot download/decrypt the n8n-secrets backup, or it has no N8N_ENCRYPTION_KEY"; fi
      age_days=$(( ( $(date +%s) - $(date -d "$d" +%s 2>/dev/null || echo 0) ) / 86400 ))
      if (( age_days > 35 )); then warn "key backup is $age_days days old (Sealed Secrets rotates keys every ~30 days): newer secrets in git may not decrypt"; fi
    else bad "no matching sealing-keys-DATE + n8n-secrets-DATE pair on Drive (BACKUP_DATE='$BACKUP_DATE')"; fi
  fi

  echo " target cluster"
  local ctx minor defsc mem=0 cpu m c
  ctx=$(kubectl config current-context 2>/dev/null || true)
  if [[ -n "$ctx" ]] && kubectl get ns >/dev/null 2>&1; then ok "cluster reachable (context: $ctx)"; else die "no reachable cluster: point kubectl at the NEW cluster first"; fi
  minor=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor // empty' | tr -dc '0-9')
  if [[ -n "$minor" && "$minor" -ge 28 ]]; then ok "Kubernetes 1.$minor"; else warn "Kubernetes version unclear or older than 1.28 (1.${minor:-?})"; fi
  defsc=$(kubectl get storageclass -o json | jq '[.items[]|select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")]|length')
  if [[ "$defsc" == 1 ]]; then ok "exactly one default StorageClass"; else bad "need exactly one default StorageClass (found $defsc)"; fi
  for m in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}'); do mem=$((mem+$(to_mib "$m"))); done
  cpu=$(for c in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}'); do to_cores "$c"; done | awk '{s+=$1} END{print s+0}')
  if (( mem >= 10240 )); then ok "memory for pods: $((mem/1024)) GiB"; else warn "only $((mem/1024)) GiB allocatable; the full platform wants ~12 GiB (pods may stay Pending)"; fi
  if awk -v c="$cpu" 'BEGIN{exit !(c>=4)}'; then ok "CPU for pods: $cpu cores"; else warn "only $cpu CPU cores allocatable; ~6 recommended"; fi
  leftovers > "$TMP/left.txt"
  if (( LEFT == 0 )); then ok "cluster is empty (no platform leftovers)"
  else
    bad "cluster is NOT empty ($LEFT item(s)). If this is the failed DR cluster run: ./ops/dr-up.sh clean. If it is your live cluster, STOP."
    sed -n 1,12p "$TMP/left.txt" | sed 's/^/          /'
  fi
  if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then log "note: this cluster already has metrics-server; the Argo metrics-server app is skipped when it is not ours"; fi

  echo " network and pinned versions"
  for u in https://github.com https://raw.githubusercontent.com https://ghcr.io/v2/ https://quay.io/v2/ https://registry-1.docker.io/v2/ \
           "https://github.com/bitnami/sealed-secrets/releases/download/$SEALED_SECRETS_VERSION/controller.yaml" \
           "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"; do
    code=$(curl -sIL -o /dev/null -m 25 -w '%{http_code}' "$u" || true)
    case "$code" in 2*|3*|401) ok "reachable: ${u#https://}" ;; *) bad "cannot reach $u (HTTP ${code:-none})" ;; esac
  done
  # every chart pinned in argocd/apps (and kube-prometheus-stack) must still exist in its registry
  local repo chart ver
  { awk '/repoURL:/{r=$NF} /^ *chart:/{c=$NF} /targetRevision:/{ if(c!=""){print r, c, $NF}; c="" }' "$REPO"/argocd/apps/*.yaml | tr -d '"'
    echo "https://prometheus-community.github.io/helm-charts kube-prometheus-stack $KPS_VERSION"; } |
  while read -r repo chart ver; do
    case "$repo" in
      http://*|https://*) helm show chart "$chart" --repo "$repo" --version "$ver" >/dev/null 2>&1 ;;
      *)                  helm show chart "oci://$repo/$chart" --version "$ver" >/dev/null 2>&1 ;;
    esac && echo "OK $chart $ver" || echo "NO $chart $ver ($repo)"
  done > "$TMP/charts.txt"
  while read -r t chart ver rest; do
    if [[ "$t" == OK ]]; then ok "chart exists: $chart $ver"; else bad "chart NOT found: $chart $ver $rest (removed from the registry? update the pin in git)"; fi
  done < "$TMP/charts.txt"

  echo " options"
  if [[ -n "$MONITORING_VALUES" && ! -r "$MONITORING_VALUES" ]]; then bad "MONITORING_VALUES not readable"; fi
  if [[ -n "$ALERTMANAGER_VALUES" && -r "$ALERTMANAGER_VALUES" ]]; then ok "Alertmanager values file found"; else warn "no ALERTMANAGER_VALUES: alert e-mail routing will NOT be restored"; fi
  if [[ "$MODE" == drill ]]; then
    warn "DRILL: the restored n8n will run your ACTIVE workflows (schedules, polling) next to production. START_N8N=0 leaves n8n off."
  else log "REAL mode: the new WAL archive folder will be <cluster>-dr<timestamp>"; fi

  step "pre-DR summary: $PASS passed, $WARN warnings, $FAIL failed"
  if (( FAIL > 0 )); then die "pre-DR checks failed: fix the FAIL lines above (nothing was changed)"; fi
}

# =============================================================================
#  BUILD
# =============================================================================
step_sealed_secrets() {
  step "1/8 Restore the Sealed Secrets keys, then install the controller"
  kubectl apply -f "$TMP/keys.json" >/dev/null
  retry 5 10 kubectl apply -f "https://github.com/bitnami/sealed-secrets/releases/download/$SEALED_SECRETS_VERSION/controller.yaml" >/dev/null
  kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s >/dev/null
  log "controller ready; keys in cluster: $(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l | tr -d ' ')"
}

step_argocd() {
  step "2/8 Install Argo CD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n argocd --server-side --force-conflicts -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null
  wait_crd applications.argoproj.io
  kubectl -n argocd wait --for=condition=Available deploy --all --timeout=600s >/dev/null
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
  # apps whose repoURL has no scheme are OCI registries (ghcr.io/..., registry-1.docker.io/...): Argo needs them registered
  local u s
  for u in $(cat "$REPO"/argocd/apps/*.yaml "$REPO"/bootstrap/root.yaml | awk '/repoURL:/{print $NF}' | tr -d '"' | sort -u); do
    case "$u" in http://*|https://*) continue ;; esac
    s="repo-oci-$(slug "$u")"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $s
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: $s
  type: helm
  url: $u
  enableOCI: "true"
EOF
    log "registered OCI registry $u"
  done
}

step_monitoring() {
  step "3/8 Install kube-prometheus-stack $KPS_VERSION (ServiceMonitor/PrometheusRule CRDs and Prometheus)"
  local args=() c
  if [[ -n "$MONITORING_VALUES" ]]; then args+=(-f "$MONITORING_VALUES")
  else args+=(--set kubeControllerManager.enabled=false --set kubeScheduler.enabled=false --set kubeEtcd.enabled=false --set kubeProxy.enabled=false); fi
  if [[ -n "$ALERTMANAGER_VALUES" && -r "$ALERTMANAGER_VALUES" ]]; then args+=(-f "$ALERTMANAGER_VALUES"); fi
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" -n monitoring --create-namespace "${args[@]}" --timeout 10m >/dev/null
  for c in servicemonitors podmonitors prometheusrules; do wait_crd "$c.monitoring.coreos.com"; done
  kubectl -n monitoring rollout status deploy/prometheus-kube-prometheus-operator --timeout=600s >/dev/null
}

step_platform() {
  step "4/8 Install the platform apps from git (cert-manager, CNPG + Barman plugin, KEDA, VPA, metrics-server)"
  local f name apps=() d
  for f in "$REPO"/argocd/apps/*.yaml; do
    name=$(app_name "$f")
    case "$name" in n8n|n8n-base|redis-ha) continue ;; esac
    if [[ "$name" == metrics-server ]] && kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1 &&
       [[ -z "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null)" ]]; then
      log "skipping metrics-server: the cluster already provides one"; continue
    fi
    kubectl apply -f "$f" >/dev/null; apps+=("$name")
  done
  wait_apps 1800 "${apps[@]}" || die "platform apps did not become healthy (kubectl -n argocd get app)"
  wait_crd clusters.postgresql.cnpg.io; wait_crd objectstores.barmancloud.cnpg.io
  wait_crd scaledobjects.keda.sh; wait_crd verticalpodautoscalers.autoscaling.k8s.io
  for d in $(kubectl -n cnpg-system get deploy -o name); do kubectl -n cnpg-system rollout status "$d" --timeout=300s >/dev/null; done
  log "operators and the Barman plugin are running"
}

step_base() {
  step "5/8 Apply deploy/base through Argo (everything except the Postgres Cluster)"
  local skip="Cluster|CronJob" files
  if [[ "$MODE" == drill ]]; then skip="$skip|ScheduledBackup"; fi
  files=$(grep -lE "^kind: ($skip)[[:space:]]*\$" "$REPO"/deploy/base/*.yaml | xargs -n1 basename | paste -sd,)
  log "left out on purpose: $files"
  kubectl create namespace "$REDIS_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  y2j "$(app_file n8n-base)" | jq --arg ex "{$files}" '.spec.source.directory = ((.spec.source.directory // {}) + {exclude: $ex})' | kubectl apply -f - >/dev/null

  wait_until 600 "SealedSecrets to exist" bash -c "[ \"\$(kubectl get sealedsecrets.bitnami.com -A --no-headers 2>/dev/null | wc -l)\" -ge 1 ]" ||
    die "n8n-base created no SealedSecrets (kubectl -n argocd describe app n8n-base)"
  wait_until 300 "every SealedSecret to decrypt" bash -c "! kubectl get sealedsecrets.bitnami.com -A -o json | jq -e '[.items[]|select(([.status.conditions[]?|select(.type==\"Synced\" and .status==\"True\")]|length)==0)]|length>0' >/dev/null" ||
    { kubectl get sealedsecrets.bitnami.com -A; die "some SealedSecrets did not decrypt: the restored keys do not match what git was sealed with"; }
  local live want
  live=$(kubectl -n "$N8N_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' 2>/dev/null || true)
  want=$(jq -r '.data.N8N_ENCRYPTION_KEY' "$TMP/n8n-secrets.json")
  [[ -n "$live" && "$live" == "$want" ]] || die "N8N_ENCRYPTION_KEY in git (SealedSecret) != your Drive backup: restored credentials would be unreadable. Stop and investigate."
  log "all SealedSecrets decrypted; the encryption key matches your backup"
}

# cluster facts come from the repo's own Cluster manifest
load_cluster_info() {
  local f; f=$(file_of Cluster); [[ -n "$f" ]] || die "no Cluster manifest in deploy/base"
  y2j "$f" | sed -n 1p > "$TMP/cluster.json"
  CL=$(jq -r '.metadata.name' "$TMP/cluster.json")
  CLNS=$(jq -r '.metadata.namespace // "n8n"' "$TMP/cluster.json")
  DB=$(jq -r '.spec.bootstrap.initdb.database // "app"' "$TMP/cluster.json")
  OWNER=$(jq -r '.spec.bootstrap.initdb.owner // "app"' "$TMP/cluster.json")
  OS=$(jq -r --arg p "$PLUGIN" '[.spec.plugins[]? | select(.name==$p) | .parameters.barmanObjectName][0] // empty' "$TMP/cluster.json")
  [[ -n "$OS" ]] || die "the Cluster manifest has no $PLUGIN plugin / barmanObjectName"
  GIT_SERVER=$(jq -r --arg p "$PLUGIN" '[.spec.plugins[]? | select(.name==$p) | .parameters.serverName][0] // empty' "$TMP/cluster.json")
  SRC="${SOURCE_SERVER:-${GIT_SERVER:-$CL}}"
}

# run a shell command in a throw-away rclone pod that has the ObjectStore's own S3 credentials ($DEST = bucket/path)
s3_run() {
  local pod="dr-s3probe-$RANDOM" osj ph="" end
  osj=$(kubectl -n "$CLNS" get objectstores.barmancloud.cnpg.io "$OS" -o json)
  jq -n --arg name "$pod" --arg ns "$CLNS" --arg cmd "$1" --argjson os "$osj" '
    ($os.spec.configuration) as $c | ($c.destinationPath | sub("^s3://";"") | sub("/$";"")) as $dest |
    { apiVersion:"v1", kind:"Pod", metadata:{name:$name, namespace:$ns, labels:{app:"dr-s3probe"}},
      spec:{ restartPolicy:"Never", automountServiceAccountToken:false,
        securityContext:{runAsNonRoot:true, runAsUser:26, runAsGroup:26, seccompProfile:{type:"RuntimeDefault"}},
        containers:[{ name:"rclone", image:"rclone/rclone:1.68.2", command:["sh","-c",$cmd],
          securityContext:{allowPrivilegeEscalation:false, capabilities:{drop:["ALL"]}},
          env:([{name:"HOME",value:"/tmp"}, {name:"DEST",value:$dest}, {name:"RCLONE_CONFIG_S3_TYPE",value:"s3"},
                {name:"RCLONE_CONFIG_S3_PROVIDER",value:(if $c.endpointURL then "Other" else "AWS" end)},
                {name:"RCLONE_CONFIG_S3_NO_CHECK_BUCKET",value:"true"},
                {name:"RCLONE_CONFIG_S3_ACCESS_KEY_ID",valueFrom:{secretKeyRef:{name:$c.s3Credentials.accessKeyId.name,key:$c.s3Credentials.accessKeyId.key}}},
                {name:"RCLONE_CONFIG_S3_SECRET_ACCESS_KEY",valueFrom:{secretKeyRef:{name:$c.s3Credentials.secretAccessKey.name,key:$c.s3Credentials.secretAccessKey.key}}}]
               + (if $c.s3Credentials.region then [{name:"RCLONE_CONFIG_S3_REGION",valueFrom:{secretKeyRef:{name:$c.s3Credentials.region.name,key:$c.s3Credentials.region.key}}}] else [] end)
               + (if $c.endpointURL then [{name:"RCLONE_CONFIG_S3_ENDPOINT",value:$c.endpointURL}] else [] end)) }] } }' |
    kubectl apply -f - >/dev/null
  end=$((SECONDS+240))
  while (( SECONDS < end )); do
    ph=$(kubectl -n "$CLNS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$ph" == Succeeded || "$ph" == Failed ]]; then break; fi
    sleep 4
  done
  kubectl -n "$CLNS" logs "$pod" 2>&1 || true
  kubectl -n "$CLNS" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  [[ "$ph" == Succeeded ]]
}

primary()  { kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.status.currentPrimary}'; }
psql_q()   { kubectl -n "$CLNS" exec "$(primary)" -c postgres -- psql -U postgres -d "$1" -tAc "$2"; }   # psql_q <db> <sql>

step_database() {
  step "6/8 Restore Postgres from the S3 archive  [mode: $MODE${TARGET_TIME:+, target $TARGET_TIME}]"
  load_cluster_info
  if (( FRESH_DB )) && kubectl -n "$CLNS" get cluster "$CL" >/dev/null 2>&1; then
    log "--fresh-db: deleting the existing $CL"
    kubectl -n "$CLNS" delete cluster "$CL" --wait=true --timeout=300s >/dev/null
    kubectl -n "$CLNS" delete pvc -l "cnpg.io/cluster=$CL" --wait=true --timeout=300s >/dev/null 2>&1 || true
  fi
  if kubectl -n "$CLNS" get cluster "$CL" >/dev/null 2>&1; then
    log "Cluster $CL already exists: not touching it (use --fresh-db to redo the restore)"
  else
    local probe folders nb nw
    probe=$(s3_run 'echo "---SERVERS---"; rclone lsf "s3:$DEST/" --dirs-only; echo "---BASE---"; rclone lsf "s3:$DEST/'"$SRC"'/base/" --dirs-only; echo "---WALS---"; rclone lsf "s3:$DEST/'"$SRC"'/wals/" --dirs-only | sed -n 1,3p') ||
      { echo "$probe" >&2; die "cannot read the S3 archive (wrong credentials or bucket?)"; }
    folders=$(sed -n '/---SERVERS---/,/---BASE---/p' <<<"$probe" | { grep -v -- '---' || true; } | tr -d '/' | paste -sd' ')
    nb=$(sed -n '/---BASE---/,/---WALS---/p' <<<"$probe" | { grep -v -- '---' || true; } | wc -l | tr -d ' ')
    nw=$(sed -n '/---WALS---/,$p' <<<"$probe" | { grep -v -- '---' || true; } | wc -l | tr -d ' ')
    log "S3 server folders: ${folders:-none}"
    if [[ "$nb" -ge 1 && "$nw" -ge 1 ]]; then ok "S3 archive '$SRC' holds base backup(s) and WAL"
    else die "no base backup + WAL under '$SRC' (folders: ${folders:-none}). Pick one with SOURCE_SERVER=<folder>"; fi
    if [[ "$MODE" == real ]]; then NEW_SERVER="${CL}-dr$(date -u +%Y%m%d%H%M)"; fi
    jq --arg os "$OS" --arg src "$SRC" --arg db "$DB" --arg owner "$OWNER" --arg t "$TARGET_TIME" --arg new "$NEW_SERVER" --arg p "$PLUGIN" '
        .spec.bootstrap = { recovery: ({source:"origin", database:$db, owner:$owner} + (if $t=="" then {} else {recoveryTarget:{targetTime:$t}} end)) }
        | .spec.externalClusters = [{name:"origin", plugin:{name:$p, parameters:{barmanObjectName:$os, serverName:$src}}}]
        | (if $new=="" then del(.spec.plugins)
           else .spec.plugins = [{name:$p, isWALArchiver:true, parameters:{barmanObjectName:$os, serverName:$new}}] end)
        | del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations)' \
      "$TMP/cluster.json" > "$TMP/cluster-recovery.json"
    retry 10 15 kubectl apply -f "$TMP/cluster-recovery.json" >/dev/null || die "could not create the Cluster (operator webhook not ready?)"
    log "recovery started (timeout ${RECOVERY_TIMEOUT}s): restoring from '$SRC'${NEW_SERVER:+, archiving to '$NEW_SERVER'}"
  fi
  local end=$((SECONDS+RECOVERY_TIMEOUT)) ready inst phase
  while :; do
    phase=$(kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ready=$(kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
    inst=$(kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.spec.instances}' 2>/dev/null || true)
    log "cluster phase: ${phase:-pending}   ready: ${ready:-0}/${inst:-?}"
    if [[ -n "$inst" && "${ready:-0}" == "$inst" ]]; then break; fi
    if kubectl -n "$CLNS" get pods -l cnpg.io/jobRole=full-recovery -o json 2>/dev/null | jq -e '[.items[]|select(.status.phase=="Failed")]|length>0' >/dev/null 2>&1; then
      kubectl -n "$CLNS" logs -l cnpg.io/jobRole=full-recovery --all-containers --tail=40 >&2 || true
      die "the recovery job failed (log above). Typical causes: TARGET_TIME outside the archived range, wrong SOURCE_SERVER, bad S3 credentials. Fix, then re-run with --fresh-db."
    fi
    if (( SECONDS >= end )); then die "database restore timed out (kubectl -n $CLNS describe cluster $CL)"; fi
    sleep 30
  done
  if [[ "$MODE" == real && -z "$NEW_SERVER" ]]; then
    NEW_SERVER=$(kubectl -n "$CLNS" get cluster "$CL" -o json | jq -r --arg p "$PLUGIN" '[.spec.plugins[]? | select(.name==$p) | .parameters.serverName][0] // empty')
  fi
  local wf cr last
  wf=$(psql_q "$DB" 'select count(*) from workflow_entity' 2>/dev/null || echo "?")
  cr=$(psql_q "$DB" 'select count(*) from credentials_entity' 2>/dev/null || echo "?")
  last=$(psql_q "$DB" "select coalesce(max(\"startedAt\")::text,'none') from execution_entity" 2>/dev/null || echo "?")
  log "restored data: workflows=$wf credentials=$cr newest execution=$last"
  [[ "$wf" =~ ^[0-9]+$ && "$wf" -gt 0 ]] || die "the restored database has no workflows: wrong backup, SOURCE_SERVER or TARGET_TIME?"
}

step_apps() {
  step "7/8 Start Redis, then n8n"
  kubectl apply -f "$(app_file redis-ha)" >/dev/null
  wait_apps 1500 redis-ha || die "redis-ha did not become healthy"
  local p d
  for p in $(kubectl -n "$CLNS" get pooler.postgresql.cnpg.io -o name 2>/dev/null); do
    wait_until 300 "pooler deployment ${p#*/}" kubectl -n "$CLNS" get deploy "${p#*/}" || true
    kubectl -n "$CLNS" rollout status "deploy/${p#*/}" --timeout=300s >/dev/null || warn "pooler ${p#*/} not ready"
  done
  if [[ "$START_N8N" != 1 ]]; then warn "START_N8N=$START_N8N: n8n was NOT started"; return 0; fi
  kubectl apply -f "$(app_file n8n)" >/dev/null
  wait_apps 1200 n8n || warn "the n8n Argo app is not Healthy yet; the post-DR checks will show details"
  for d in $(kubectl -n "$N8N_NS" get deploy -o name); do kubectl -n "$N8N_NS" rollout status "$d" --timeout=600s >/dev/null || warn "$d not fully rolled out"; done
}

step_real_backup() {
  if [[ "$MODE" != real ]]; then return 0; fi
  step "8/8 REAL mode: take a first base backup so the NEW archive is recoverable"
  local bk; bk="dr-initial-$(date -u +%Y%m%d%H%M%S)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: $bk, namespace: $CLNS }
spec:
  cluster: { name: $CL }
  method: plugin
  pluginConfiguration: { name: $PLUGIN }
EOF
  if wait_until 1500 "backup $bk" bash -c "[ \"\$(kubectl -n $CLNS get backup $bk -o jsonpath='{.status.phase}')\" = completed ]"; then log "base backup $bk completed"
  else warn "base backup $bk not completed yet (kubectl -n $CLNS get backup)"; fi
}

# =============================================================================
#  POST-DR CHECKS  (read-only)
# =============================================================================
post_checks() {
  step "POST-DR CHECKS"
  PASS=0; WARN=0; FAIL=0
  if [[ ! -s "$TMP/cluster.json" ]]; then load_cluster_info; fi
  local x inst ready n wf cr last p rpw rpod code

  echo " GitOps and secrets"
  x=$(kubectl -n argocd get applications -o json | jq -r '.items[]|select(.status.sync.status!="Synced" or .status.health.status!="Healthy")|"\(.metadata.name)=\(.status.sync.status)/\(.status.health.status)"' | paste -sd' ')
  if [[ -z "$x" ]]; then ok "all Argo apps Synced + Healthy"; else warn "Argo apps not green: $x"; fi
  x=$(kubectl get sealedsecrets.bitnami.com -A -o json | jq -r '.items[]|select(([.status.conditions[]?|select(.type=="Synced" and .status=="True")]|length)==0)|"\(.metadata.namespace)/\(.metadata.name)"' | paste -sd' ')
  if [[ -z "$x" ]]; then ok "every SealedSecret decrypted into a Secret"; else bad "SealedSecrets not decrypted: $x"; fi
  if [[ -s "$TMP/n8n-secrets.json" ]]; then
    if [[ "$(kubectl -n "$N8N_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' 2>/dev/null)" == "$(jq -r '.data.N8N_ENCRYPTION_KEY' "$TMP/n8n-secrets.json")" ]]; then
      ok "N8N_ENCRYPTION_KEY matches the Drive backup"; else bad "N8N_ENCRYPTION_KEY differs from the Drive backup"; fi
  fi

  echo " pods"
  x=$(kubectl get pods -A -o json | jq -r '.items[]|select((.status.phase!="Running" and .status.phase!="Succeeded") or (.status.phase=="Running" and ([.status.containerStatuses[]?|select(.ready==false)]|length>0)))|"\(.metadata.namespace)/\(.metadata.name)"')
  if [[ -z "$x" ]]; then ok "all pods Running/Completed and Ready"
  else
    if grep -qv '^monitoring/' <<<"$x"; then bad "pods not ready: $(grep -v '^monitoring/' <<<"$x" | paste -sd' ')"; fi
    if grep -q '^monitoring/' <<<"$x"; then warn "$(grep -c '^monitoring/' <<<"$x") monitoring pod(s) still starting (not critical)"; fi
  fi

  echo " Postgres"
  inst=$(kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.spec.instances}')
  ready=$(kubectl -n "$CLNS" get cluster "$CL" -o jsonpath='{.status.readyInstances}')
  if [[ "$ready" == "$inst" ]]; then ok "$ready/$inst instances ready (primary: $(primary))"; else bad "only ${ready:-0}/$inst instances ready"; fi
  n=$(psql_q postgres "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null || echo 0)
  if [[ "$n" -ge $((inst-1)) ]]; then ok "$n replica(s) streaming"; else bad "replication: $n streaming, expected $((inst-1))"; fi
  p=$(kubectl -n "$CLNS" get secret "${CL}-app" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)
  if [[ -n "$p" ]] && printf '%s' "$p" | kubectl -n "$CLNS" exec -i "$(primary)" -c postgres -- \
       sh -c "IFS= read -r PGPASSWORD; export PGPASSWORD; psql -h ${CL}-rw -U $OWNER -d $DB -tAc 'select 1'" >/dev/null 2>&1; then
    ok "app user '$OWNER' can log in with the password in ${CL}-app"
  else bad "app login failed: secret ${CL}-app missing or wrong password"; fi
  if kubectl -n "$CLNS" get secret n8n-db-ca >/dev/null 2>&1; then ok "TLS CA secret n8n-db-ca exists (n8n verifies the database with it)"; else bad "secret n8n-db-ca is missing: n8n cannot verify the database"; fi
  x=$(psql_q postgres "select count(*) filter (where s.ssl) || '|' || count(*) filter (where not s.ssl) from pg_stat_ssl s join pg_stat_activity a using(pid) where a.usename='$OWNER'" 2>/dev/null || echo "?")
  if [[ "$x" =~ ^[0-9]+\|0$ && "${x%%|*}" -gt 0 ]]; then ok "connections of '$OWNER' use TLS ($x = tls|plain)"
  elif [[ "$x" == "?" || "$x" == "0|0" ]]; then warn "no '$OWNER' connections yet to judge TLS"
  else bad "plain-text connections of '$OWNER' exist ($x = tls|plain)"; fi
  wf=$(psql_q "$DB" 'select count(*) from workflow_entity' 2>/dev/null || echo "?")
  cr=$(psql_q "$DB" 'select count(*) from credentials_entity' 2>/dev/null || echo "?")
  last=$(psql_q "$DB" "select coalesce(max(\"startedAt\")::text,'none') from execution_entity" 2>/dev/null || echo "?")
  if [[ "$wf" =~ ^[0-9]+$ && "$wf" -gt 0 ]]; then ok "data present: workflows=$wf credentials=$cr newest execution=$last (compare with when the outage began = your data loss)"; else bad "no workflows found in $DB"; fi

  echo " backups"
  if [[ "$(kubectl -n "$CLNS" get cluster "$CL" -o json | jq '(.spec.plugins // [])|length')" -gt 0 ]]; then
    psql_q postgres 'select pg_switch_wal()' >/dev/null 2>&1 || true; sleep 25
    x=$(psql_q postgres "select coalesce(failed_count,0)||'|'||(last_archived_time is not null) from pg_stat_archiver" 2>/dev/null || echo "?")
    if [[ "$x" == "0|true" || "$x" == "0|t" ]]; then ok "WAL archiving works (archived a file, 0 failures)"; else bad "WAL archiving problem (failed|archived = $x): kubectl -n $CLNS logs $(primary) -c plugin-barman-cloud"; fi
    n=$(kubectl -n "$CLNS" get backups.postgresql.cnpg.io -o json | jq '[.items[]|select(.status.phase=="completed")]|length')
    if [[ "$n" -ge 1 ]]; then ok "$n completed base backup(s) in the NEW archive"; else bad "no completed base backup yet: the new archive is not recoverable until one completes"; fi
  else ok "DRILL: this cluster is NOT archiving, so it cannot touch the production S3 archive"; fi

  echo " Redis and autoscaling"
  rpw=$(kubectl -n "$REDIS_NS" get secret redis-cluster-auth -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 --decode || true)
  rpod=$(kubectl -n "$REDIS_NS" get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$rpod" && -n "$rpw" ]] && printf '%s' "$rpw" | kubectl -n "$REDIS_NS" exec -i "$rpod" -- sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; redis-cli cluster info' 2>/dev/null | grep -q 'cluster_state:ok'; then
    ok "Redis cluster_state:ok"; else bad "Redis cluster not healthy (or password secret missing)"; fi
  x=$(kubectl -n "$N8N_NS" get scaledobjects.keda.sh -o json 2>/dev/null | jq -r '.items[]|select(([.status.conditions[]?|select(.type=="Ready" and .status=="True")]|length)==0)|.metadata.name' | paste -sd' ')
  if [[ -z "$x" ]]; then ok "KEDA ScaledObjects Ready"; else warn "KEDA ScaledObjects not Ready: $x"; fi

  echo " n8n"
  if kubectl -n argocd get application n8n >/dev/null 2>&1; then
    x=$(kubectl -n "$N8N_NS" get deploy -o json | jq -r '.items[]|select((.status.availableReplicas // 0) < (.spec.replicas // 1))|"\(.metadata.name) \(.status.availableReplicas // 0)/\(.spec.replicas)"' | paste -sd';')
    if [[ -z "$x" ]]; then ok "all n8n deployments have their replicas available"; else bad "deployments short of replicas: $x"; fi
    if kubectl -n "$N8N_NS" get svc nginx-proxy >/dev/null 2>&1; then
      pf_start "$N8N_NS" svc/nginx-proxy 18443 443
      code=$(curl -ks -o /dev/null -m 15 -w '%{http_code}' https://localhost:18443/healthz || true)
      if [[ "$code" == 200 ]]; then ok "n8n answers over HTTPS through the nginx proxy (/healthz = 200)"; else bad "/healthz via the proxy returned HTTP ${code:-none}"; fi
      code=$(curl -ks -o /dev/null -m 15 -w '%{http_code}' https://localhost:18443/healthz/readiness || true)
      if [[ "$code" == 200 ]]; then ok "n8n is ready: it reaches Postgres over TLS (/healthz/readiness = 200)"; else bad "/healthz/readiness returned HTTP ${code:-none} (database connection problem?)"; fi
      code=$(curl -ks -o /dev/null -m 15 -w '%{http_code}' https://localhost:18443/metrics || true)
      if [[ "$code" == 404 ]]; then ok "/metrics is blocked at the proxy"; else warn "/metrics via the proxy returned HTTP ${code:-none} (expected 404)"; fi
      pf_stop
    else warn "no nginx-proxy service found"; fi
  else warn "n8n Argo app not installed (START_N8N=0?): n8n checks skipped"; fi

  echo " security and monitoring"
  n=$(kubectl -n "$N8N_NS" get networkpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -ge 5 ]]; then ok "$n NetworkPolicies in $N8N_NS"; else bad "only $n NetworkPolicies in $N8N_NS (expected the full set)"; fi
  if kubectl -n monitoring get prometheusrule n8n-backup-alerts >/dev/null 2>&1; then ok "alert rules n8n-backup-alerts are loaded"; else bad "PrometheusRule n8n-backup-alerts is missing"; fi
  if kubectl -n monitoring get svc prometheus-kube-prometheus-prometheus >/dev/null 2>&1; then
    pf_start monitoring svc/prometheus-kube-prometheus-prometheus 19090 9090
    x="?"; n=0
    while (( n < 12 )); do
      x=$(curl -s -m 10 -G --data-urlencode 'query=count(up{namespace="n8n"}==0) or vector(0)' http://localhost:19090/api/v1/query | jq -r '.data.result[0].value[1] // "?"' 2>/dev/null || echo "?")
      if [[ "$x" == 0 ]]; then break; fi
      n=$((n+1)); sleep 10
    done
    pf_stop
    if [[ "$x" == 0 ]]; then ok "Prometheus scrapes every n8n target (none down)"; else warn "Prometheus reports $x n8n target(s) down or unknown (give it a few minutes)"; fi
  else warn "Prometheus service not found"; fi
  if [[ -z "$ALERTMANAGER_VALUES" ]]; then warn "Alertmanager has no receiver: alerts will not reach you"; fi

  step "post-DR summary: $PASS passed, $WARN warnings, $FAIL failed"
  cat <<EOF

 Checks the script cannot do for you (2 minutes):
   1. kubectl -n $N8N_NS port-forward svc/nginx-proxy 8443:443   then open https://localhost:8443 and log in
   2. open a credential and run a workflow that uses it  (proves the encryption key works)
   3. run a workflow and watch a worker pick it up and finish
EOF
}

handover_notes() {
  if [[ "$MODE" == real ]]; then cat <<EOF

${B}REAL mode: what is left to do by hand${N}
 The new cluster archives to a NEW folder in the same bucket:  serverName = ${NEW_SERVER:-see the Cluster}
 Argo's 'n8n-base' runs without the Postgres Cluster (it would fight the restored one). To hand over to GitOps:
   1. In deploy/base/postgres-cluster.yaml set under spec.plugins[].parameters:   serverName: ${NEW_SERVER:-<new folder>}
   2. In argocd/apps/n8n-base.yaml add (so Argo never re-applies creation-time fields):
        ignoreDifferences:
          - group: postgresql.cnpg.io
            kind: Cluster
            jsonPointers: [/spec/bootstrap, /spec/externalClusters]
      and add RespectIgnoreDifferences=true to syncOptions
   3. git commit + push, then:   kubectl apply -f bootstrap/root.yaml
   4. keep a note: the old archive folder is '${SRC:-?}', the new one is '${NEW_SERVER:-?}'
      (next time: SOURCE_SERVER=<newest folder> ./ops/dr-up.sh)
EOF
  else cat <<EOF

${B}DRILL mode: finished${N}
 This cluster does NOT archive to S3, and the 'root' app and the Postgres Cluster from git were NOT applied,
 so nothing here can write to your production archive. Delete the cluster (or run ./ops/dr-up.sh clean) when done.
 To run it for real:   ./ops/dr-up.sh --real
EOF
  fi
}

# ----------------------------------- main ------------------------------------
case "$CMD" in
  preflight) preflight ;;
  clean)     clean ;;
  verify)    post_checks ;;
  up)
    T0=$SECONDS
    preflight
    confirm "This will INSTALL the full platform into that cluster."
    step_sealed_secrets; step_argocd; step_monitoring; step_platform; step_base
    step_database; step_apps; step_real_backup
    post_checks; handover_notes
    echo; echo "total time: $(( (SECONDS-T0)/60 )) min"
    if (( FAIL > 0 )); then exit 1; fi ;;
esac
