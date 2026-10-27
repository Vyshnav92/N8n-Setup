#!/usr/bin/env bash
# =============================================================================
# dr-up.sh - rebuild the n8n platform on an EMPTY Kubernetes cluster from
#            the git repo + your backups (Google Drive keys + S3 PITR archive).
#
#   ./dr-up.sh                run everything: pre-DR checks -> build -> post-DR checks
#                             (DRILL mode: safe, never writes to your production S3 archive)
#   ./dr-up.sh --real         same, but the new cluster keeps archiving WAL to S3
#                             (use this in a REAL disaster, when the old cluster is gone)
#   ./dr-up.sh preflight      pre-DR checks only (changes nothing)
#   ./dr-up.sh verify         post-DR checks only
#   ./dr-up.sh readiness      run against your CURRENT/production cluster: "are we DR-ready?"
#                             (also writes ops/dr-versions.env so a rebuild uses the same versions)
#
# Required:  AGE_IDENTITY=/path/to/age-identity.txt   (private key for your encrypted key backups)
# Optional:  see the "settings" block below (all can be passed as environment variables)
# =============================================================================
set -Eeuo pipefail

# ------------------------------- settings ------------------------------------
MODE="${DR_MODE:-drill}"                       # drill | real
GDRIVE_PATH="${GDRIVE_PATH:-gdrive:n8n-dr}"    # where keys-backup.sh uploads
AGE_IDENTITY="${AGE_IDENTITY:-}"
REPO_URL="${REPO_URL:-https://github.com/Vyshnav92/N8n-Setup.git}"
REPO_DIR="${REPO_DIR:-}"                       # default: the repo this script lives in, else ~/N8n-Setup-dr
ALERTMANAGER_VALUES="${ALERTMANAGER_VALUES:-}" # your gitignored alertmanager-values.yaml (optional)
ARGOCD_SSH_KEY="${ARGOCD_SSH_KEY:-}"           # only if your repo is private / apps use git@ URLs and you want SSH
TARGET_TIME="${TARGET_TIME:-}"                 # PITR target e.g. 2026-10-26T12:00:00Z (empty = latest possible)
SEALING_KEYS_FILE="${SEALING_KEYS_FILE:-}"     # default: newest sealing-keys-*.json.age on Drive
N8N_SECRETS_FILE="${N8N_SECRETS_FILE:-}"       # default: newest n8n-secrets-*.json.age on Drive
N8N_NS="${N8N_NS:-n8n}"
N8N_SECRET_NAME="${N8N_SECRET_NAME:-n8n-secrets}"
SOURCE_SERVER_NAME="${SOURCE_SERVER_NAME:-}"   # folder name of the old cluster inside the S3 archive (default: cluster name)
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-2400}"   # seconds to wait for the database restore
ALLOW_NONEMPTY="${ALLOW_NONEMPTY:-0}"          # 1 = allow running on a cluster that already has platform namespaces
CONFIRM_CONTEXT="${CONFIRM_CONTEXT:-}"         # non-interactive: set to the kubectl context name you intend to modify
# Version pins for things that are NOT in git (filled in by `readiness`, or set by hand; empty = latest)
ARGOCD_VERSION="${ARGOCD_VERSION:-}"
SEALED_SECRETS_CHART_VERSION="${SEALED_SECRETS_CHART_VERSION:-}"
PROM_STACK_CHART_VERSION="${PROM_STACK_CHART_VERSION:-}"
# -----------------------------------------------------------------------------

CMD=up
for a in "$@"; do
  case "$a" in
    up|preflight|verify|readiness) CMD=$a ;;
    --real)  MODE=real ;;
    --drill) MODE=drill ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)"; exit 2 ;;
  esac
done
[[ "$MODE" == drill || "$MODE" == real ]] || { echo "DR_MODE must be drill or real"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$REPO_DIR" ]]; then
  if [[ -d "$SCRIPT_DIR/../deploy/base" ]]; then REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; else REPO_DIR="$HOME/N8n-Setup-dr"; fi
fi

# ------------------------------- tiny helpers --------------------------------
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else R=; G=; Y=; B=; N=; fi
PASS=0; WARN=0; FAIL=0; T0=$SECONDS; NEW_SERVER=""; S3_PROBE_LOG=""
ok()   { echo "  ${G}PASS${N}  $*"; PASS=$((PASS+1)); }
warn() { echo "  ${Y}WARN${N}  $*"; WARN=$((WARN+1)); }
bad()  { echo "  ${R}FAIL${N}  $*"; FAIL=$((FAIL+1)); }
log()  { echo "        $*"; }
step() { echo; echo "${B}==> $*${N}"; }
die()  { echo "${R}ERROR:${N} $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

TMP="$(mktemp -d)"; chmod 700 "$TMP"; PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'echo "${R}ERROR:${N} failed at line $LINENO (see message above)" >&2' ERR

to_mib()   { awk -v v="$1" 'BEGIN{ if(v~/Ki$/){sub(/Ki$/,"",v);print int(v/1024)} else if(v~/Mi$/){sub(/Mi$/,"",v);print int(v)} else if(v~/Gi$/){sub(/Gi$/,"",v);print int(v*1024)} else print int(v/1048576) }'; }
to_cores() { awk -v v="$1" 'BEGIN{ if(v~/m$/){sub(/m$/,"",v);print v/1000} else print v+0 }'; }
slug()     { echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-50; }

# wait_until <seconds> <description> <command...>   (polls every 5s)
wait_until() {
  local t=$1 d=$2; shift 2; local end=$((SECONDS+t))
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= end )); then echo "timed out waiting for: $d" >&2; return 1; fi
    sleep 5
  done
}
wait_crd() { wait_until 900 "CRD $1" kubectl get crd "$1" || die "CRD $1 never appeared"; kubectl wait --for=condition=Established "crd/$1" --timeout=180s >/dev/null; }

app_ok() { kubectl -n argocd get app "$1" -o json 2>/dev/null | jq -e '.status.sync.status=="Synced" and .status.health.status=="Healthy"' >/dev/null 2>&1; }
# wait until Argo apps are Synced+Healthy; re-trigger a sync every ~2 min if one is stuck
wait_apps() {
  local timeout=$1; shift; local end=$((SECONDS+timeout)) kick=$SECONDS a pending
  while :; do
    pending=""
    for a in "$@"; do app_ok "$a" || pending="$pending $a"; done
    [[ -z "$pending" ]] && return 0
    if (( SECONDS >= end )); then echo "Argo apps not ready:$pending" >&2; return 1; fi
    if (( SECONDS - kick > 120 )); then
      for a in $pending; do
        if ! kubectl -n argocd get app "$a" -o json | jq -e 'has("operation")' >/dev/null 2>&1; then
          kubectl -n argocd patch app "$a" --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true
        fi
      done; kick=$SECONDS
    fi
    log "waiting for Argo apps:$pending"; sleep 15
  done
}

app_name() { awk '/^  name:/{print $2; exit}' "$1"; }
# app_file <app-name>  -> path of the manifest that defines that Argo app
app_file() { local f; for f in "$REPO_DIR"/argocd/apps/*.yaml; do [[ "$(app_name "$f")" == "$1" ]] && { echo "$f"; return 0; }; done; return 1; }

# Argo app manifests are applied through this so we can swap git@ URLs for https:// (public repo => no SSH key needed)
apply_app() {
  if [[ "${REWRITE_HTTPS:-0}" == 1 ]]; then sed -E 's#(repoURL: *)git@([^:]+):#\1https://\2/#' "$1" | kubectl apply -f - >/dev/null
  else kubectl apply -f "$1" >/dev/null; fi
}

ensure_repo() {
  if [[ ! -d "$REPO_DIR/deploy/base" ]]; then
    has git || die "git is needed to fetch the repo"
    if [[ -d "$REPO_DIR/.git" ]]; then git -C "$REPO_DIR" pull --ff-only -q; else git clone -q "$REPO_URL" "$REPO_DIR"; fi
  fi
  # shellcheck disable=SC1091
  if [[ -f "$REPO_DIR/ops/dr-versions.env" ]]; then . "$REPO_DIR/ops/dr-versions.env"; fi
  return 0
}

# every object under deploy/base as ONE json array (works for plain dirs and kustomize)
render_base() {
  local dir="$REPO_DIR/deploy/base"
  if [[ -f "$dir/kustomization.yaml" ]]; then kubectl kustomize "$dir" | kubectl create --dry-run=client -o json -f -
  else kubectl create --dry-run=client -o json -f "$dir"; fi | jq -cs 'map(if .kind=="List" then .items[] else . end)'
}

# fills CLUSTER_NAME CLUSTER_NS DB_NAME DB_OWNER OBJECTSTORE SOURCE_SERVER from the repo's own manifests
load_cluster_info() {
  render_base > "$TMP/all.json"
  jq -ce 'map(select(.kind=="Cluster"))|first // empty' "$TMP/all.json" > "$TMP/cluster.json" || true
  [[ -s "$TMP/cluster.json" ]] || die "no Cluster manifest found in deploy/base"
  CLUSTER_NAME=$(jq -r '.metadata.name' "$TMP/cluster.json")
  CLUSTER_NS=$(jq -r '.metadata.namespace // "n8n"' "$TMP/cluster.json")
  DB_NAME=$(jq -r '.spec.bootstrap.initdb.database // "app"' "$TMP/cluster.json")
  DB_OWNER=$(jq -r '.spec.bootstrap.initdb.owner // "app"' "$TMP/cluster.json")
  OBJECTSTORE=$(jq -r '[.spec.plugins[]?|select(.name=="barman-cloud.cloudnative-pg.io")|.parameters.barmanObjectName][0] // empty' "$TMP/cluster.json")
  [[ -n "$OBJECTSTORE" ]] || OBJECTSTORE=$(jq -r 'map(select(.kind=="ObjectStore"))|first|.metadata.name // empty' "$TMP/all.json")
  [[ -n "$OBJECTSTORE" ]] || die "no ObjectStore found (is the PITR setup in deploy/base?)"
  PLUGIN_SERVER=$(jq -r '[.spec.plugins[]?|select(.name=="barman-cloud.cloudnative-pg.io")|.parameters.serverName][0] // empty' "$TMP/cluster.json")
  SOURCE_SERVER="${SOURCE_SERVER_NAME:-${PLUGIN_SERVER:-$CLUSTER_NAME}}"
}

# Is there a base backup + WAL in S3?  Runs a throw-away aws-cli pod that uses the SAME secret the ObjectStore uses.
# usage: s3_probe <ns> <objectstore> <serverName>      result text in $S3_PROBE_LOG
s3_probe() {
  local ns=$1 os=$2 srv=$3 pod="s3probe-$RANDOM" osj dest ep epflag cmd ph end
  S3_PROBE_LOG=""
  osj=$(kubectl -n "$ns" get objectstores.barmancloud.cnpg.io "$os" -o json) || return 1
  dest=$(jq -r '.spec.configuration.destinationPath' <<<"$osj"); dest=${dest%/}
  ep=$(jq -r '.spec.configuration.endpointURL // empty' <<<"$osj")
  epflag=""; [[ -n "$ep" ]] && epflag="--endpoint-url $ep"
  cmd="set -e; aws s3 ls $epflag '$dest/$srv/base/'; echo ---WALS---; aws s3 ls $epflag '$dest/$srv/wals/' | head -3"
  jq -n --arg name "$pod" --arg ns "$ns" --arg cmd "$cmd" --argjson os "$osj" '
    ($os.spec.configuration.s3Credentials // {}) as $c
    | { apiVersion:"v1", kind:"Pod", metadata:{name:$name, namespace:$ns},
        spec:{ restartPolicy:"Never", containers:[{ name:"aws", image:"amazon/aws-cli:latest", command:["sh","-c",$cmd],
          env: ( (if $c.accessKeyId then [{name:"AWS_ACCESS_KEY_ID",valueFrom:{secretKeyRef:{name:$c.accessKeyId.name,key:$c.accessKeyId.key}}}] else [] end)
               + (if $c.secretAccessKey then [{name:"AWS_SECRET_ACCESS_KEY",valueFrom:{secretKeyRef:{name:$c.secretAccessKey.name,key:$c.secretAccessKey.key}}}] else [] end)
               + (if $c.region then [{name:"AWS_DEFAULT_REGION",valueFrom:{secretKeyRef:{name:$c.region.name,key:$c.region.key}}}] else [] end) ) }] } }' \
    | kubectl apply -f - >/dev/null
  end=$((SECONDS+300)); ph=""
  while (( SECONDS < end )); do
    ph=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ "$ph" == Succeeded || "$ph" == Failed ]] && break
    sleep 4
  done
  S3_PROBE_LOG=$(kubectl -n "$ns" logs "$pod" 2>&1 || true)
  kubectl -n "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  [[ "$ph" == Succeeded ]]
}

primary_pod() { kubectl -n "$1" get cluster "$2" -o jsonpath='{.status.currentPrimary}'; }
psql_q() {  # psql_q <ns> <cluster> <db> <sql>
  kubectl -n "$1" exec "$(primary_pod "$1" "$2")" -c postgres -- psql -U postgres -d "$3" -tAc "$4"
}

confirm_context() {
  local ctx; ctx=$(kubectl config current-context)
  echo; echo "  kubectl context: ${B}$ctx${N}"; echo "  mode: ${B}$MODE${N}   repo: $REPO_DIR @ $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "  This will INSTALL a full platform into that cluster."
  if [[ "$CONFIRM_CONTEXT" == "$ctx" ]]; then return 0; fi
  [[ -t 0 ]] || die "not a terminal: set CONFIRM_CONTEXT=$ctx to confirm non-interactively"
  local a; read -r -p "  Type the context name to continue: " a; [[ "$a" == "$ctx" ]] || die "context name did not match, aborting"
  if [[ "$MODE" == real ]]; then read -r -p "  REAL mode: type REAL to confirm: " a; [[ "$a" == REAL ]] || die "aborting"; fi
}

# =============================================================================
#  PRE-DR CHECKS  (read-only: nothing in the target cluster is changed)
# =============================================================================
pre_dr_checks() {
  step "PRE-DR CHECKS (read-only)"
  local t f ns found u code

  echo " tools"
  for t in kubectl helm jq age rclone git curl; do if has "$t"; then ok "$t installed"; else bad "$t is missing"; fi; done
  [[ "$FAIL" -eq 0 ]] || die "install the missing tools above, then re-run (nothing was changed)"

  echo " repo"
  for f in bootstrap/root.yaml argocd/apps deploy/base ops/keys-restore.sh; do
    if [[ -e "$REPO_DIR/$f" ]]; then ok "repo has $f"; else bad "repo is missing $f"; fi
  done
  grep -rqsE '^kind: Cluster[[:space:]]*$' "$REPO_DIR/deploy/base"      && ok "repo has a CloudNativePG Cluster manifest" || bad "no 'kind: Cluster' in deploy/base"
  grep -rqsE '^kind: ObjectStore[[:space:]]*$' "$REPO_DIR/deploy/base"  && ok "repo has an ObjectStore (PITR archive config)" || bad "no 'kind: ObjectStore' in deploy/base - was the PITR setup pushed?"
  grep -rqsE '^kind: SealedSecret[[:space:]]*$' "$REPO_DIR/deploy/base" && ok "repo has SealedSecrets" || bad "no SealedSecrets in deploy/base"
  grep -rqsi 'barman' "$REPO_DIR/argocd/apps"            && ok "an Argo app installs the Barman plugin" || bad "no Barman plugin app in argocd/apps"
  grep -rqsi 'cert-manager' "$REPO_DIR/argocd/apps"      && ok "an Argo app installs cert-manager" || bad "no cert-manager app in argocd/apps (the plugin needs it)"

  echo " backups & keys"
  if [[ -n "$AGE_IDENTITY" && -r "$AGE_IDENTITY" ]]; then ok "age identity file readable"; else bad "AGE_IDENTITY not set or not readable"; fi
  DRIVE_LIST=$(rclone lsf "$GDRIVE_PATH/" 2>/dev/null || true)
  if [[ -n "$DRIVE_LIST" ]]; then ok "Google Drive reachable ($GDRIVE_PATH)"; else bad "cannot list $GDRIVE_PATH (rclone 'gdrive' remote missing or token expired)"; fi
  KEYS_FILE="${SEALING_KEYS_FILE:-$(printf '%s\n' "$DRIVE_LIST" | grep -E '^sealing-keys-[0-9]{8}\.json\.age$' | sort | tail -1 || true)}"
  SECRETS_FILE="${N8N_SECRETS_FILE:-$(printf '%s\n' "$DRIVE_LIST" | grep -E '^n8n-secrets-[0-9]{8}\.json\.age$' | sort | tail -1 || true)}"
  if [[ -n "$KEYS_FILE" && -r "${AGE_IDENTITY:-/nonexistent}" ]]; then
    if rclone copyto "$GDRIVE_PATH/$KEYS_FILE" "$TMP/keys.age" 2>/dev/null && age -d -i "$AGE_IDENTITY" -o "$TMP/keys.json" "$TMP/keys.age" 2>/dev/null \
       && jq -e '.items|length>0' "$TMP/keys.json" >/dev/null 2>&1; then
      ok "$KEYS_FILE decrypts ($(jq '.items|length' "$TMP/keys.json") sealing key(s))"
    else bad "cannot download/decrypt $KEYS_FILE (wrong age identity?)"; fi
  else bad "no sealing-keys backup found/decryptable"; fi
  if [[ -n "$SECRETS_FILE" && -r "${AGE_IDENTITY:-/nonexistent}" ]]; then
    if rclone copyto "$GDRIVE_PATH/$SECRETS_FILE" "$TMP/ns.age" 2>/dev/null && age -d -i "$AGE_IDENTITY" -o "$TMP/n8n-secrets.json" "$TMP/ns.age" 2>/dev/null \
       && jq -e '.data.N8N_ENCRYPTION_KEY|length>0' "$TMP/n8n-secrets.json" >/dev/null 2>&1; then
      ok "$SECRETS_FILE decrypts and contains N8N_ENCRYPTION_KEY"
    else bad "cannot download/decrypt $SECRETS_FILE or it has no N8N_ENCRYPTION_KEY"; fi
  else bad "no n8n-secrets backup found/decryptable"; fi
  for f in "$KEYS_FILE" "$SECRETS_FILE"; do
    [[ -n "$f" ]] || continue
    local age_days
    age_days=$(rclone lsjson "$GDRIVE_PATH/" 2>/dev/null | jq -r --arg n "$f" '.[]|select(.Name==$n)|.ModTime|sub("\\.[0-9]+";"")|fromdateiso8601|((now-.)/86400|floor)' 2>/dev/null || true)
    if [[ -n "$age_days" && "$age_days" -gt 35 ]]; then warn "$f is $age_days days old (Sealed Secrets rotates keys every ~30 days)"; fi
  done

  echo " target cluster"
  local ctx; ctx=$(kubectl config current-context 2>/dev/null || true)
  if [[ -n "$ctx" ]]; then ok "kubectl context: $ctx"; else die "no kubectl context: point kubectl at the NEW cluster first"; fi
  if kubectl get ns >/dev/null 2>&1; then ok "cluster reachable"; else die "cluster not reachable with context $ctx"; fi
  local minor; minor=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor // empty' | tr -dc '0-9')
  if [[ -n "$minor" && "$minor" -ge 28 ]]; then ok "Kubernetes 1.$minor"; else warn "Kubernetes version unclear or older than 1.28 (found: 1.${minor:-?})"; fi
  found=""
  for ns in argocd "$N8N_NS" cnpg-system redis-ha monitoring cert-manager keda vpa; do kubectl get ns "$ns" >/dev/null 2>&1 && found="$found $ns" || true; done
  if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then found="$found kube-system/sealed-secrets"; fi
  if [[ -z "$found" ]]; then ok "cluster is empty (no platform namespaces yet)"
  elif [[ "$ALLOW_NONEMPTY" == 1 ]]; then warn "cluster is not empty:$found (ALLOW_NONEMPTY=1)"
  else bad "cluster is NOT empty, found:$found. Is this your live cluster? (ALLOW_NONEMPTY=1 to override)"; fi
  local defsc; defsc=$(kubectl get storageclass -o json | jq '[.items[]|select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")]|length')
  if [[ "$defsc" == 1 ]]; then ok "exactly one default StorageClass"; else bad "need exactly one default StorageClass (found $defsc)"; fi
  local mem=0 cpu=0 m c
  for m in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}'); do mem=$((mem+$(to_mib "$m"))); done
  cpu=$(for c in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}'); do to_cores "$c"; done | awk '{s+=$1} END{print s+0}')
  if [[ "$mem" -ge 10240 ]]; then ok "memory available to pods: $((mem/1024)) GiB"; else warn "only $((mem/1024)) GiB memory allocatable; ~12 GiB recommended"; fi
  if awk -v c="$cpu" 'BEGIN{exit !(c>=4)}'; then ok "CPU available to pods: $cpu cores"; else warn "only $cpu CPU cores allocatable; ~6 recommended"; fi

  echo " network (can this machine / cluster download what we need?)"
  for u in https://github.com https://raw.githubusercontent.com https://ghcr.io/v2/ https://registry-1.docker.io/v2/ https://quay.io/v2/ \
           https://charts.jetstack.io/index.yaml https://cloudnative-pg.github.io/charts/index.yaml https://bitnami-labs.github.io/sealed-secrets/index.yaml \
           https://prometheus-community.github.io/helm-charts/index.yaml https://kedacore.github.io/charts/index.yaml \
           https://charts.fairwinds.com/stable/index.yaml https://kubernetes-sigs.github.io/metrics-server/index.yaml; do
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$u" || true)
    case "$code" in 2*|3*|401) ok "reachable: $u";; *) bad "cannot reach $u (HTTP ${code:-none})";; esac
  done
  if grep -rqs 'repoURL: *git@' "$REPO_DIR/argocd/apps" "$REPO_DIR/bootstrap" 2>/dev/null; then
    if [[ -n "$ARGOCD_SSH_KEY" && -r "$ARGOCD_SSH_KEY" ]]; then ok "Argo will use your SSH deploy key"
    else
      local https; https=$(grep -rhs 'repoURL: *git@' "$REPO_DIR/argocd/apps" "$REPO_DIR/bootstrap" | head -1 | awk '{print $NF}' | sed -E 's#git@([^:]+):#https://\1/#')
      if git ls-remote "$https" HEAD >/dev/null 2>&1; then ok "repo is public over https; Argo will use https URLs (no SSH key needed)"; else bad "repo not readable over https and no ARGOCD_SSH_KEY given"; fi
    fi
  fi

  echo " version pins"
  for t in ARGOCD_VERSION SEALED_SECRETS_CHART_VERSION PROM_STACK_CHART_VERSION; do
    if [[ -n "${!t}" ]]; then ok "$t=${!t}"; else warn "$t not pinned (will install the latest; run './dr-up.sh readiness' on production to record versions)"; fi
  done
  [[ -n "$ALERTMANAGER_VALUES" && -r "$ALERTMANAGER_VALUES" ]] && ok "Alertmanager values file found" || warn "no ALERTMANAGER_VALUES: alert routing (Gmail) will NOT be restored"

  step "pre-DR summary: $PASS passed, $WARN warnings, $FAIL failed"
  [[ "$FAIL" -eq 0 ]] || die "pre-DR checks failed. Fix the FAIL lines above and re-run (nothing was changed)."
}

# =============================================================================
#  BUILD
# =============================================================================
setup_argocd_access() {
  local u s
  REWRITE_HTTPS=0
  for u in $(cat "$REPO_DIR"/argocd/apps/*.yaml "$REPO_DIR"/bootstrap/root.yaml | awk '/repoURL:/{print $NF}' | sort -u); do
    case "$u" in
      git@*|ssh://*)
        if [[ -n "$ARGOCD_SSH_KEY" ]]; then
          s="repo-$(slug "$u")"
          kubectl -n argocd create secret generic "$s" --from-literal=type=git --from-literal=url="$u" --from-file=sshPrivateKey="$ARGOCD_SSH_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
          kubectl -n argocd label secret "$s" argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
          log "registered SSH repo $u"
        else REWRITE_HTTPS=1; fi ;;
      http://*|https://*) : ;;
      *)  # no scheme => an OCI registry (ghcr.io/..., registry-1.docker.io/...)
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
        log "registered OCI registry $u" ;;
    esac
  done
  [[ "$REWRITE_HTTPS" == 1 ]] && log "apps will use https:// repo URLs (public repo)" || true
}

build() {
  confirm_context
  local BASE_NS; BASE_NS=$(awk '/^  destination:/{d=1} d && /namespace:/{print $2; exit}' "$(app_file n8n-base)" 2>/dev/null || true); BASE_NS=${BASE_NS:-$N8N_NS}

  step "1/10 Restore the Sealed Secrets private keys (BEFORE the controller exists, so it adopts them)"
  kubectl apply -f "$TMP/keys.json" >/dev/null
  log "$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l | tr -d ' ') key secret(s) in kube-system"

  step "2/10 Install the Sealed Secrets controller"
  local va=(); [[ -n "$SEALED_SECRETS_CHART_VERSION" ]] && va=(--version "$SEALED_SECRETS_CHART_VERSION")
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update >/dev/null
  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system --set fullnameOverride=sealed-secrets-controller \
    ${va[@]+"${va[@]}"} --wait --timeout 5m >/dev/null
  log "controller ready"

  step "3/10 Install Argo CD ${ARGOCD_VERSION:-(latest stable)}"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n argocd --server-side --force-conflicts -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION:-stable}/manifests/install.yaml" >/dev/null
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
  wait_crd applications.argoproj.io
  setup_argocd_access

  step "4/10 Install kube-prometheus-stack (provides the ServiceMonitor/PrometheusRule CRDs your repo uses)"
  local vp=() vv=(); [[ -n "$PROM_STACK_CHART_VERSION" ]] && vp=(--version "$PROM_STACK_CHART_VERSION")
  [[ -n "$ALERTMANAGER_VALUES" && -r "$ALERTMANAGER_VALUES" ]] && vv=(-f "$ALERTMANAGER_VALUES")
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
    ${vp[@]+"${vp[@]}"} ${vv[@]+"${vv[@]}"} --timeout 10m >/dev/null
  for c in servicemonitors podmonitors prometheusrules; do wait_crd "$c.monitoring.coreos.com"; done
  kubectl -n monitoring rollout status deploy/prometheus-kube-prometheus-operator --timeout=600s >/dev/null

  step "5/10 Install platform apps from git (operators, cert-manager, Barman plugin, KEDA, VPA, ...)"
  local platform="" f name
  for f in "$REPO_DIR"/argocd/apps/*.yaml; do
    name=$(app_name "$f")
    case "$name" in n8n|n8n-base|redis-ha) continue ;; esac   # these three are started later, in order
    apply_app "$f"; platform="$platform $name"
  done
  # shellcheck disable=SC2086
  wait_apps 1800 $platform || die "platform apps did not become healthy (check: kubectl -n argocd get app)"
  for c in clusters.postgresql.cnpg.io objectstores.barmancloud.cnpg.io; do wait_crd "$c"; done
  for c in scaledobjects.keda.sh verticalpodautoscalers.autoscaling.k8s.io; do wait_crd "$c"; done
  for d in $(kubectl -n cnpg-system get deploy -o name); do kubectl -n cnpg-system rollout status "$d" --timeout=300s >/dev/null; done
  log "operators and the Barman plugin are running"
  load_cluster_info     # needs the CRDs installed above to read the repo manifests

  step "6/10 Apply deploy/base (secrets, ObjectStore, policies, proxy ...) - everything EXCEPT the Postgres Cluster"
  jq -c --arg ns "$BASE_NS" '
      [ .[] | select([.kind] | inside(["Cluster","ScheduledBackup","CronJob","Job","Backup"]) | not) ]
      | map( if (.metadata.namespace == null and ([.kind] | inside(["Namespace","ClusterRole","ClusterRoleBinding","CustomResourceDefinition","StorageClass","PersistentVolume","ClusterIssuer"]) | not))
             then .metadata.namespace = $ns else . end )
      | sort_by(if .kind=="Namespace" then 0 else 1 end)' "$TMP/all.json" > "$TMP/base.json"
  local ns
  for ns in $(jq -r --arg cns "$CLUSTER_NS" '([.[]|select(.kind=="Namespace")|.metadata.name]) as $def
        | ([.[]|.metadata.namespace // empty] + [$cns]) | unique | map(select(. as $n | ($def|index($n))|not)) | .[]' "$TMP/base.json"); do
    kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
  done
  jq '{apiVersion:"v1",kind:"List",items:.}' "$TMP/base.json" | kubectl apply -f - >/dev/null
  log "applied $(jq length "$TMP/base.json") objects; skipped Cluster/ScheduledBackup/CronJobs on purpose"

  step "7/10 Decrypt secrets + verify the n8n encryption key matches your backup"
  wait_until 300 "SealedSecrets to unseal" bash -c "! kubectl get sealedsecrets.bitnami.com -A -o json | jq -e '[.items[]|select(([.status.conditions[]?|select(.type==\"Synced\" and .status==\"True\")]|length)==0)]|length>0' >/dev/null" \
    || { kubectl get sealedsecrets.bitnami.com -A; die "some SealedSecrets did not decrypt: the restored sealing keys do not match what the repo was sealed with"; }
  local live want
  live=$(kubectl -n "$N8N_NS" get secret "$N8N_SECRET_NAME" -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' 2>/dev/null || true)
  want=$(jq -r '.data.N8N_ENCRYPTION_KEY' "$TMP/n8n-secrets.json")
  [[ -n "$live" && "$live" == "$want" ]] || die "N8N_ENCRYPTION_KEY from git (SealedSecret) != the one in your Drive backup. Restored credentials would be unreadable. Stop and investigate."
  log "all SealedSecrets decrypted; encryption key matches the backup"

  step "8/10 Restore Postgres from the S3 archive (Barman recovery)  [mode: $MODE${TARGET_TIME:+, target $TARGET_TIME}]"
  NEW_SERVER=""
  if s3_probe "$CLUSTER_NS" "$OBJECTSTORE" "$SOURCE_SERVER"; then
    log "S3 archive reachable: $(printf '%s\n' "$S3_PROBE_LOG" | sed '/---WALS---/,$d' | grep -c PRE || true) base backup(s) found for '$SOURCE_SERVER'"
  else echo "$S3_PROBE_LOG" >&2; die "cannot find a base backup + WAL for '$SOURCE_SERVER' in S3 (wrong credentials, bucket or serverName?)"; fi
  [[ "$MODE" == real ]] && NEW_SERVER="${CLUSTER_NAME}-dr$(date -u +%Y%m%d%H%M)"
  jq --arg os "$OBJECTSTORE" --arg src "$SOURCE_SERVER" --arg db "$DB_NAME" --arg owner "$DB_OWNER" --arg target "$TARGET_TIME" --arg mode "$MODE" --arg newsrv "$NEW_SERVER" '
      .spec.bootstrap = { recovery: ({source:"origin", database:$db, owner:$owner} + (if $target=="" then {} else {recoveryTarget:{targetTime:$target}} end)) }
      | .spec.externalClusters = [{name:"origin", plugin:{name:"barman-cloud.cloudnative-pg.io", parameters:{barmanObjectName:$os, serverName:$src}}}]
      | (if $mode=="real"
           then .spec.plugins = [{name:"barman-cloud.cloudnative-pg.io", isWALArchiver:true, parameters:{barmanObjectName:$os, serverName:$newsrv}}]
           else del(.spec.plugins) end)
      | del(.metadata.annotations, .metadata.creationTimestamp, .metadata.uid, .metadata.resourceVersion, .status)' "$TMP/cluster.json" > "$TMP/cluster-recovery.json"
  kubectl apply -f "$TMP/cluster-recovery.json" >/dev/null
  log "recovery started; this can take a while (timeout ${RECOVERY_TIMEOUT}s)"
  local end=$((SECONDS+RECOVERY_TIMEOUT)) ready inst phase
  while :; do
    phase=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ready=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
    inst=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.instances}' 2>/dev/null || true)
    log "cluster phase: ${phase:-pending}  ready: ${ready:-0}/${inst:-?}"
    if [[ -n "$inst" && "${ready:-0}" == "$inst" ]]; then break; fi
    if kubectl -n "$CLUSTER_NS" get pods -l cnpg.io/jobRole=full-recovery -o json 2>/dev/null | jq -e '[.items[]|select(.status.phase=="Failed")]|length>0' >/dev/null 2>&1; then
      kubectl -n "$CLUSTER_NS" logs -l cnpg.io/jobRole=full-recovery --all-containers --tail=40 >&2 || true
      die "the recovery job failed (log above). Common causes: targetTime outside the archived range, bad S3 credentials."
    fi
    (( SECONDS < end )) || die "database restore timed out after ${RECOVERY_TIMEOUT}s (kubectl -n $CLUSTER_NS describe cluster $CLUSTER_NAME)"
    sleep 30
  done

  step "9/10 Sanity-check the restored data BEFORE starting n8n"
  local wf cr last
  wf=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select count(*) from workflow_entity;' 2>/dev/null || echo "?")
  cr=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select count(*) from credentials_entity;' 2>/dev/null || echo "?")
  last=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select coalesce(max("startedAt")::text,'"'"'none'"'"') from execution_entity;' 2>/dev/null || echo "?")
  log "workflows=$wf  credentials=$cr  newest execution=$last"
  [[ "$wf" =~ ^[0-9]+$ && "$wf" -gt 0 ]] || die "restored database has no workflows (or the table is missing): wrong backup, serverName or targetTime?"

  step "10/10 Start Redis, then n8n"
  apply_app "$(app_file redis-ha)"
  wait_apps 1500 redis-ha || die "redis-ha did not become healthy"
  apply_app "$(app_file n8n)"
  wait_apps 1200 n8n || warn "n8n Argo app not Healthy yet; post-DR checks will show details"
  local d
  for d in $(kubectl -n "$N8N_NS" get deploy -o name); do kubectl -n "$N8N_NS" rollout status "$d" --timeout=600s >/dev/null || warn "$d not fully rolled out yet"; done

  if [[ "$MODE" == real ]]; then
    step "REAL mode: take a fresh base backup so the NEW archive ('$NEW_SERVER') is recoverable"
    local bk="dr-initial-$(date -u +%Y%m%d%H%M%S)"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: $bk, namespace: $CLUSTER_NS }
spec:
  cluster: { name: $CLUSTER_NAME }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
    wait_until 1500 "base backup $bk" bash -c "[ \"\$(kubectl -n $CLUSTER_NS get backup $bk -o jsonpath='{.status.phase}')\" = completed ]" \
      && log "base backup $bk completed" || warn "base backup $bk not completed yet (kubectl -n $CLUSTER_NS get backup)"
  fi
}

# =============================================================================
#  POST-DR CHECKS  (read-only)
# =============================================================================
post_dr_checks() {
  step "POST-DR CHECKS"
  PASS=0; WARN=0; FAIL=0
  [[ -s "$TMP/cluster.json" ]] || load_cluster_info
  local lines p inst ready n

  echo " GitOps / secrets"
  lines=$(kubectl -n argocd get app -o json | jq -r '.items[]|select(.status.sync.status!="Synced" or .status.health.status!="Healthy")|"\(.metadata.name) sync=\(.status.sync.status) health=\(.status.health.status)"')
  if [[ -z "$lines" ]]; then ok "all Argo apps Synced + Healthy"; else warn "Argo apps not green: $(echo "$lines" | tr '\n' ';')"; fi
  lines=$(kubectl get sealedsecrets.bitnami.com -A -o json | jq -r '.items[]|select(([.status.conditions[]?|select(.type=="Synced" and .status=="True")]|length)==0)|"\(.metadata.namespace)/\(.metadata.name)"')
  if [[ -z "$lines" ]]; then ok "every SealedSecret decrypted into a Secret"; else bad "SealedSecrets not decrypted: $(echo "$lines" | tr '\n' ' ')"; fi

  echo " pods"
  lines=$(kubectl get pods -A -o json | jq -r '.items[]
      | select((.status.phase!="Running" and .status.phase!="Succeeded") or (.status.phase=="Running" and ([.status.containerStatuses[]?|select(.ready==false)]|length>0)))
      | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"')
  if [[ -z "$lines" ]]; then ok "all pods Running/Completed and Ready"
  else
    if echo "$lines" | grep -vq '^monitoring/'; then bad "pods not ready: $(echo "$lines" | grep -v '^monitoring/' | tr '\n' ';')"; fi
    if echo "$lines" | grep -q '^monitoring/'; then warn "monitoring pods still starting (not critical): $(echo "$lines" | grep '^monitoring/' | wc -l | tr -d ' ') pod(s)"; fi
  fi

  echo " Postgres"
  inst=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.instances}')
  ready=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.status.readyInstances}')
  if [[ "$ready" == "$inst" ]]; then ok "$ready/$inst instances ready (primary: $(primary_pod "$CLUSTER_NS" "$CLUSTER_NAME"))"; else bad "only ${ready:-0}/$inst instances ready"; fi
  n=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" postgres "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null || echo 0)
  if [[ "$n" -ge $((inst-1)) ]]; then ok "$n replica(s) streaming"; else bad "replication: $n streaming, expected $((inst-1))"; fi
  p=$(kubectl -n "$CLUSTER_NS" get secret "${CLUSTER_NAME}-app" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)
  if [[ -n "$p" ]] && printf '%s' "$p" | kubectl -n "$CLUSTER_NS" exec -i "$(primary_pod "$CLUSTER_NS" "$CLUSTER_NAME")" -c postgres -- \
       sh -c "IFS= read -r PGPASSWORD; export PGPASSWORD; psql -h ${CLUSTER_NAME}-rw -U $DB_OWNER -d $DB_NAME -tAc 'select 1'" >/dev/null 2>&1; then
    ok "app user '$DB_OWNER' can log in through ${CLUSTER_NAME}-rw with the password in ${CLUSTER_NAME}-app (what n8n uses)"
  else bad "app login failed: secret ${CLUSTER_NAME}-app missing or password wrong - n8n would not be able to connect"; fi
  local wf cr last
  wf=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select count(*) from workflow_entity;' 2>/dev/null || echo "?")
  cr=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select count(*) from credentials_entity;' 2>/dev/null || echo "?")
  last=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" "$DB_NAME" 'select coalesce(max("startedAt")::text,'"'"'none'"'"') from execution_entity;' 2>/dev/null || echo "?")
  if [[ "$wf" =~ ^[0-9]+$ && "$wf" -gt 0 ]]; then ok "data present: workflows=$wf credentials=$cr, newest execution=$last (compare with when the outage began = your data loss)"; else bad "no workflows found in $DB_NAME"; fi

  echo " backups / archiving"
  if [[ "$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o json | jq '(.spec.plugins // [])|length')" -gt 0 ]]; then
    psql_q "$CLUSTER_NS" "$CLUSTER_NAME" postgres 'select pg_switch_wal()' >/dev/null 2>&1 || true; sleep 25
    local arch; arch=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" postgres 'select coalesce(failed_count,0)||'"'|'"'||(last_archived_time is not null) from pg_stat_archiver' 2>/dev/null || echo "?")
    if [[ "$arch" == "0|t" ]]; then ok "WAL archiving works (archived at least one file, 0 failures)"; else bad "WAL archiving problem (failed|archived = $arch). See: kubectl -n $CLUSTER_NS logs <primary> -c plugin-barman-cloud"; fi
    n=$(kubectl -n "$CLUSTER_NS" get backups.postgresql.cnpg.io -o json | jq '[.items[]|select(.status.phase=="completed")]|length')
    if [[ "$n" -ge 1 ]]; then ok "$n completed base backup(s) in the NEW archive"; else bad "no completed base backup yet: the new archive is not recoverable until one completes"; fi
  else
    ok "DRILL mode: this cluster is NOT archiving, so it cannot touch your production S3 archive"
    if kubectl get scheduledbackups.postgresql.cnpg.io -A --no-headers 2>/dev/null | grep -q .; then warn "a ScheduledBackup exists in a DRILL cluster; delete it before handing over to Argo"; fi
  fi

  echo " Redis / autoscaling / n8n"
  local rpw rpod
  rpw=$(kubectl -n redis-ha get secret redis-cluster-auth -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 --decode || true)
  rpod=$(kubectl -n redis-ha get pods -o name 2>/dev/null | head -1)
  if [[ -n "$rpod" && -n "$rpw" ]] && printf '%s' "$rpw" | kubectl -n redis-ha exec -i "$rpod" -- sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; redis-cli cluster info' 2>/dev/null | grep -q 'cluster_state:ok'; then
    ok "Redis cluster_state:ok"; else bad "Redis cluster is not healthy (or password secret missing)"; fi
  lines=$(kubectl -n "$N8N_NS" get scaledobjects.keda.sh -o json 2>/dev/null | jq -r '.items[]|select(([.status.conditions[]?|select(.type=="Ready" and .status=="True")]|length)==0)|.metadata.name')
  if [[ -z "$lines" ]]; then ok "KEDA ScaledObjects Ready"; else warn "KEDA ScaledObjects not Ready: $lines"; fi
  lines=$(kubectl -n "$N8N_NS" get deploy -o json | jq -r '.items[]|select((.status.availableReplicas // 0) < (.spec.replicas // 1))|"\(.metadata.name) \(.status.availableReplicas // 0)/\(.spec.replicas)"')
  if [[ -z "$lines" ]]; then ok "all n8n deployments have their replicas available"; else bad "deployments short of replicas: $(echo "$lines" | tr '\n' ';')"; fi
  local svc port code
  svc=$(kubectl -n "$N8N_NS" get svc -o name | grep -m1 nginx || true)
  if [[ -n "$svc" ]]; then
    port=$(kubectl -n "$N8N_NS" get "$svc" -o jsonpath='{.spec.ports[0].port}')
    kubectl -n "$N8N_NS" port-forward "$svc" "18443:$port" >/dev/null 2>&1 & PF_PID=$!
    sleep 5
    code=$(curl -ks -o /dev/null -m 15 -w '%{http_code}' https://localhost:18443/healthz || true)
    kill "$PF_PID" >/dev/null 2>&1 || true; PF_PID=""
    if [[ "$code" == 200 ]]; then ok "n8n answers over HTTPS through the nginx proxy (/healthz = 200)"; else warn "n8n /healthz via the proxy returned HTTP ${code:-none}; check manually with the port-forward below"; fi
  else warn "no nginx proxy service found to test"; fi

  step "post-DR summary: $PASS passed, $WARN warnings, $FAIL failed"
  cat <<EOF

 Checks the script cannot do for you (2 minutes):
   1. kubectl -n $N8N_NS port-forward svc/nginx-proxy 8443:443   ->  open https://localhost:8443  and log in
   2. open a credential and run a workflow that uses it  (proves the encryption key works)
   3. confirm workers pick up executions (run a workflow, watch it finish)
EOF
}

handover_notes() {
  if [[ "$MODE" == real ]]; then cat <<EOF

${B}REAL mode: what is left to do by hand${N}
 The new cluster archives to a NEW folder in the same bucket:  serverName = $NEW_SERVER
 Argo's 'n8n-base' app is intentionally NOT started yet (it would fight the restored Cluster). To hand over to GitOps:
   1. In deploy/base/postgres-cluster.yaml set under spec.plugins[].parameters:   serverName: $NEW_SERVER
   2. In argocd/apps/n8n-base.yaml add, so Argo never re-applies creation-time fields:
        ignoreDifferences:
          - group: postgresql.cnpg.io
            kind: Cluster
            jsonPointers: [/spec/bootstrap, /spec/externalClusters]
        (and add  RespectIgnoreDifferences=true  to syncOptions)
   3. git commit + push, then:   kubectl apply -f bootstrap/root.yaml   (use https:// repoURLs or register an SSH key first)
   4. keep a copy of these values: the old archive folder is '$SOURCE_SERVER', the new one is '$NEW_SERVER'
EOF
  else cat <<EOF

${B}DRILL mode: finished${N}
 This cluster does NOT archive to S3 and 'n8n-base'/'root' were NOT applied, so nothing can write to your production archive.
 Tear it down when done. To run the same thing for real:   ./dr-up.sh --real
EOF
  fi
}

# =============================================================================
#  READINESS  (run against production: "if the building burned down tonight, could we rebuild?")
# =============================================================================
readiness() {
  step "DR READINESS of the CURRENT cluster: $(kubectl config current-context)"
  local t; for t in kubectl jq rclone; do has "$t" || die "$t is required"; done
  load_cluster_info
  local inst ready row age_s failed lf bk_age n

  inst=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.instances}')
  ready=$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.status.readyInstances}')
  if [[ "$ready" == "$inst" ]]; then ok "Postgres healthy ($ready/$inst)"; else bad "Postgres has only ${ready:-0}/$inst instances ready"; fi

  row=$(psql_q "$CLUSTER_NS" "$CLUSTER_NAME" postgres "select coalesce(extract(epoch from now()-last_archived_time)::int,-1)||'|'||coalesce(failed_count,0)||'|'||coalesce(extract(epoch from now()-last_failed_time)::int,-1) from pg_stat_archiver" 2>/dev/null || echo "")
  if [[ -z "$row" ]]; then bad "could not read pg_stat_archiver"
  else
    age_s=${row%%|*}; failed=$(echo "$row" | cut -d'|' -f2); lf=${row##*|}
    if [[ "$age_s" == -1 ]]; then bad "WAL has NEVER been archived"
    elif [[ "$lf" != -1 && "$lf" -lt "$age_s" ]]; then bad "WAL archiving is FAILING right now (last failure ${lf}s ago, last success ${age_s}s ago)"
    elif [[ "$age_s" -gt 1800 ]]; then warn "newest archived WAL is $((age_s/60)) min old (idle database?)"
    else ok "WAL archiving healthy (newest file archived ${age_s}s ago, $failed historical failures)"; fi
  fi

  bk_age=$(kubectl -n "$CLUSTER_NS" get backups.postgresql.cnpg.io -o json | jq -r '[.items[]|select(.status.phase=="completed")|.status.stoppedAt|sub("\\.[0-9]+";"")|fromdateiso8601]|max // 0|((now-.)/3600|floor)')
  if [[ "$bk_age" -lt 36 ]]; then ok "newest completed base backup is ${bk_age}h old"; else bad "newest completed base backup is ${bk_age}h old (limit 36h)"; fi

  if s3_probe "$CLUSTER_NS" "$OBJECTSTORE" "$SOURCE_SERVER"; then ok "S3 archive readable: base backups and WAL present"; else bad "S3 archive probe failed: $(echo "$S3_PROBE_LOG" | tail -2 | tr '\n' ' ')"; fi

  DRIVE_LIST=$(rclone lsf "$GDRIVE_PATH/" 2>/dev/null || true)
  [[ -n "$DRIVE_LIST" ]] && ok "Google Drive reachable" || bad "cannot list $GDRIVE_PATH"
  local kf sf
  kf=$(printf '%s\n' "$DRIVE_LIST" | grep -E '^sealing-keys-[0-9]{8}\.json\.age$' | sort | tail -1 || true)
  sf=$(printf '%s\n' "$DRIVE_LIST" | grep -E '^n8n-secrets-[0-9]{8}\.json\.age$' | sort | tail -1 || true)
  if [[ -n "$AGE_IDENTITY" && -r "$AGE_IDENTITY" && -n "$kf" && -n "$sf" ]] && has age; then
    rclone copyto "$GDRIVE_PATH/$kf" "$TMP/k.age" && age -d -i "$AGE_IDENTITY" -o "$TMP/k.json" "$TMP/k.age"
    rclone copyto "$GDRIVE_PATH/$sf" "$TMP/s.age" && age -d -i "$AGE_IDENTITY" -o "$TMP/s.json" "$TMP/s.age"
    local missing
    missing=$(comm -23 <(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o json | jq -r '.items[].metadata.name' | sort) \
                       <(jq -r '.items[].metadata.name' "$TMP/k.json" | sort))
    if [[ -z "$missing" ]]; then ok "$kf contains every current sealing key"; else bad "$kf is MISSING current sealing key(s): $(echo "$missing" | tr '\n' ' ') -> run ops/keys-backup.sh now"; fi
    if [[ "$(kubectl -n "$N8N_NS" get secret "$N8N_SECRET_NAME" -o jsonpath='{.data.N8N_ENCRYPTION_KEY}')" == "$(jq -r '.data.N8N_ENCRYPTION_KEY' "$TMP/s.json")" ]]; then
      ok "$sf matches the live N8N_ENCRYPTION_KEY"; else bad "$sf does NOT match the live N8N_ENCRYPTION_KEY -> run ops/keys-backup.sh now"; fi
  else warn "set AGE_IDENTITY (and have both backups on Drive) to verify the key backups' CONTENT, not just their existence"; fi

  # record the versions of everything that is NOT in git, so a rebuild can install the same ones
  local av sv pv out="$REPO_DIR/ops/dr-versions.env"
  av=$(kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://' || true)
  sv=$(helm list -A -o json 2>/dev/null | jq -r '.[]|select(.chart|startswith("sealed-secrets-"))|.chart' | head -1 | sed 's/^sealed-secrets-//' || true)
  pv=$(helm list -A -o json 2>/dev/null | jq -r '.[]|select(.chart|startswith("kube-prometheus-stack-"))|.chart' | head -1 | sed 's/^kube-prometheus-stack-//' || true)
  { echo "# written by 'dr-up.sh readiness' on $(date -u +%FT%TZ) - commit this file; dr-up.sh sources it"
    echo ": \"\${ARGOCD_VERSION:=$av}\""; echo ": \"\${SEALED_SECRETS_CHART_VERSION:=$sv}\""; echo ": \"\${PROM_STACK_CHART_VERSION:=$pv}\""; } > "$out"
  log "wrote $out  (argocd=${av:-?} sealed-secrets=${sv:-?} kube-prometheus-stack=${pv:-?}) -> git add/commit/push it"
  [[ -n "$av" && -n "$sv" && -n "$pv" ]] || warn "some versions could not be detected (not installed via helm?). Edit $out by hand."

  step "readiness summary: $PASS passed, $WARN warnings, $FAIL failed"
  [[ "$FAIL" -eq 0 ]] || { echo "${R}NOT DR-READY${N}: fix the FAIL lines."; return 1; }
  echo "${G}DR-ready${N} (as far as these checks can tell: the only real proof is a drill restore)."
}

# ----------------------------------- main ------------------------------------
ensure_repo
case "$CMD" in
  readiness) readiness ;;
  preflight) pre_dr_checks ;;
  verify)    load_cluster_info; post_dr_checks ;;
  up)        pre_dr_checks; build; post_dr_checks; handover_notes
             echo; echo "total time: $(( (SECONDS-T0)/60 )) min"
             [[ "$FAIL" -eq 0 ]] || exit 1 ;;
esac
