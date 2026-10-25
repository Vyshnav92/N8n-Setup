#!/usr/bin/env bash
# DR rebuild entry point. See usage below; run from a clean clone with kubectl
# configured for the destination cluster.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
cd "$REPO_ROOT"

START_EPOCH=$(date +%s)
WAIT_SCALE="${WAIT_SCALE:-1}"
VERSIONS_FILE="${VERSIONS_FILE:-$REPO_ROOT/dr/versions.env}"
MONITORING_VALUES="${MONITORING_VALUES:-$REPO_ROOT/dr/monitoring-values.yaml}"
ALERTMANAGER_VALUES="${ALERTMANAGER_VALUES:-}"
ARGOCD_REPO_SSH_KEY="${ARGOCD_REPO_SSH_KEY:-}"
AGE_IDENTITY="${AGE_IDENTITY:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
DUMP_KEY="${DUMP_KEY:-latest}"
DATE="${DATE:-}"
FROM_STEP=""
PLAN_ONLY=0 ASSUME_YES=0 FORCE=0

DRIVE_REMOTE="gdrive:n8n-dr"
SS_NS="kube-system"
SS_DEPLOY="sealed-secrets-controller"
STEPS=(controller argocd monitoring platform base verify restore n8n finish)
CURRENT_STEP="preflight"
WORK=""
KEY_COUNT=0
EXPECTED_KEY_B64=""

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*" >&2; }
die()  { log "FAIL  $*" >&2; exit 1; }
banner() { CURRENT_STEP="$1"; printf '\n==== [%s] %s ====\n' "$1" "$2"; }
cleanup() {
  local rc=$?
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
  if (( rc != 0 )); then
    echo; echo "dr-up FAILED during step: $CURRENT_STEP (exit code $rc)"
    local s
    s=$(kubectl -n n8n get cronjob pg-backup -o jsonpath='{.spec.suspend}' 2>/dev/null || true)
    [[ "$s" == true ]] && echo "Backups are still SUSPENDED (intentional until restore is done)."
    [[ "$CURRENT_STEP" == preflight ]] || echo "Fix the cause, then resume with the same options plus: --from $CURRENT_STEP"
  fi
  return "$rc"
}
trap cleanup EXIT
usage() { sed -n '2,27p' "$SELF" | sed 's/^# \{0,1\}//'; }
scaled() { awk -v t="$1" -v s="$WAIT_SCALE" 'BEGIN { v=int(t*s); if(v<1)v=1; print v }'; }
wait_for() {
  local what=$1 timeout interval=$3 deadline last=0 now
  timeout=$(scaled "$2"); shift 3; deadline=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    now=$(date +%s)
    if (( now >= deadline )); then warn "timed out after ${timeout}s waiting for: $what"; return 1; fi
    if (( now-last >= 30 )); then log "...waiting for $what"; last=$now; fi
    sleep "$interval"
  done
  ok "$what"
}
must_wait() { local what=$1; wait_for "$@" || die "gave up waiting for: $what"; }
exists() { kubectl "$@" >/dev/null 2>&1; }
app_state() { kubectl -n argocd get application "$1" -o jsonpath='{.status.health.status}/{.status.sync.status}' 2>/dev/null || true; }
app_healthy() { [[ "$(app_state "$1")" == Healthy/* ]]; }
app_ready() { [[ "$(app_state "$1")" == Healthy/Synced ]]; }
cluster_ready() { [[ "$(kubectl -n n8n get cluster.postgresql.cnpg.io n8n-db -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == True ]]; }
deploy_ready() { local v; v=$(kubectl -n n8n get deploy "$1" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true); [[ "${v:-0}" -ge 1 ]]; }
sealedsecrets_synced() { kubectl get sealedsecret -A -o json 2>/dev/null | jq -e '(.items | length)>0 and ([.items[] | ((.status.conditions // []) | any(.type=="Synced" and .status=="True"))] | all)' >/dev/null; }
job_succeeded() { [[ "$(kubectl -n n8n get job "$1" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)" == 1 ]]; }
job_failed() { local v; v=$(kubectl -n n8n get job "$1" -o jsonpath='{.status.failed}' 2>/dev/null || true); [[ "${v:-0}" -ge 1 ]]; }

while (( $# )); do
  case "$1" in
    --date) DATE="${2:?--date needs a value}"; shift 2 ;;
    --age-identity) AGE_IDENTITY="${2:?--age-identity needs a value}"; shift 2 ;;
    --rclone-config) RCLONE_CONFIG="${2:?--rclone-config needs a value}"; shift 2 ;;
    --dump) DUMP_KEY="${2:?--dump needs a value}"; shift 2 ;;
    --from) FROM_STEP="${2:?--from needs a value}"; shift 2 ;;
    --plan) PLAN_ONLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
step_index() { local i; for i in "${!STEPS[@]}"; do [[ "${STEPS[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }
should_run() { [[ -z "$FROM_STEP" ]] && return 0; [[ $(step_index "$1") -ge $(step_index "$FROM_STEP") ]]; }

fetch_keys() {
  log "fetching and decrypting key backups from $DRIVE_REMOTE (decryption stays on this machine)"
  umask 077; WORK=$(mktemp -d)
  local listing f
  listing=$(rclone lsf "$DRIVE_REMOTE" --files-only) || die "cannot list $DRIVE_REMOTE (check config and gdrive remote)"
  if [[ "$DATE" == latest ]]; then
    f=$(grep -E '^sealing-keys-[0-9]{8}\.json\.age$' <<<"$listing" | sort | tail -n 1 || true)
    [[ -n "$f" ]] || die "no sealing-keys backup found in $DRIVE_REMOTE"
    DATE=${f#sealing-keys-}; DATE=${DATE%.json.age}
  fi
  [[ "$DATE" =~ ^[0-9]{8}$ ]] || die "--date must look like YYYYMMDD (or latest)"
  grep -qx "sealing-keys-$DATE.json.age" <<<"$listing" || die "sealing-keys-$DATE.json.age not found on Drive"
  grep -qx "n8n-secrets-$DATE.json.age" <<<"$listing" || die "n8n-secrets-$DATE.json.age not found on Drive"
  log "using key backup dated $DATE"
  rclone copyto "$DRIVE_REMOTE/sealing-keys-$DATE.json.age" "$WORK/sealing.age"
  rclone copyto "$DRIVE_REMOTE/n8n-secrets-$DATE.json.age" "$WORK/n8n.age"
  age -d -i "$AGE_IDENTITY" -o "$WORK/sealing-keys.json" "$WORK/sealing.age" || die "cannot decrypt sealing key backup"
  age -d -i "$AGE_IDENTITY" -o "$WORK/n8n-secrets.json" "$WORK/n8n.age" || die "cannot decrypt n8n secret backup"
  jq -e --arg ns "$SS_NS" '.kind=="List" and (.items|length)>0 and all(.items[]; .metadata.namespace==$ns and .data["tls.crt"]!=null and .data["tls.key"]!=null)' "$WORK/sealing-keys.json" >/dev/null || die "sealing keys backup is invalid"
  KEY_COUNT=$(jq '.items|length' "$WORK/sealing-keys.json")
  EXPECTED_KEY_B64=$(jq -r '.data.N8N_ENCRYPTION_KEY // empty' "$WORK/n8n-secrets.json")
  [[ -n "$EXPECTED_KEY_B64" ]] || die "n8n secrets backup has no N8N_ENCRYPTION_KEY"
  ok "keys decrypted: $KEY_COUNT sealing key(s), N8N_ENCRYPTION_KEY present"
}

preflight() {
  banner preflight "read-only checks (nothing is changed yet)"
  local t missing=()
  for t in kubectl helm jq age rclone git; do command -v "$t" >/dev/null || missing+=("$t"); done
  (( ${#missing[@]}==0 )) || die "missing tools: ${missing[*]}"
  [[ -n "$DATE" ]] || die "--date is required (YYYYMMDD or latest)"
  [[ -r "$AGE_IDENTITY" ]] || die "--age-identity file not readable: '$AGE_IDENTITY'"
  [[ -r "$RCLONE_CONFIG" ]] || die "--rclone-config file not readable: '$RCLONE_CONFIG'"
  export RCLONE_CONFIG
  if [[ "$DUMP_KEY" != latest && ! "$DUMP_KEY" =~ ^n8n-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then die "invalid --dump name"; fi
  [[ -z "$FROM_STEP" ]] || step_index "$FROM_STEP" >/dev/null || die "unknown --from step: $FROM_STEP"
  [[ -r "$VERSIONS_FILE" ]] || die "versions file not found: $VERSIONS_FILE"
  # shellcheck disable=SC1090
  source "$VERSIONS_FILE"
  SEALED_SECRETS_INSTALL="${SEALED_SECRETS_INSTALL:-manifest}"
  local bad=()
  for t in ARGOCD_VERSION KPS_VERSION; do [[ -n "${!t:-}" && "${!t}" != CHANGE_ME ]] || bad+=("$t"); done
  if [[ "$SEALED_SECRETS_INSTALL" == helm ]]; then
    [[ -n "${SEALED_SECRETS_CHART_VERSION:-}" && "$SEALED_SECRETS_CHART_VERSION" != CHANGE_ME ]] || bad+=(SEALED_SECRETS_CHART_VERSION)
  else
    [[ -n "${SEALED_SECRETS_VERSION:-}" && "$SEALED_SECRETS_VERSION" != CHANGE_ME ]] || bad+=(SEALED_SECRETS_VERSION)
  fi
  (( ${#bad[@]}==0 )) || die "fill these in $VERSIONS_FILE first: ${bad[*]}"
  if grep -q 'git@github.com' bootstrap/root.yaml argocd/apps/*.yaml 2>/dev/null; then
    [[ -r "$ARGOCD_REPO_SSH_KEY" ]] || die "GitHub SSH URLs remain; provide ARGOCD_REPO_SSH_KEY or change repo URLs"
  fi
  grep -q '^  name: pg-restore$' ops/pg-restore-job.yaml || die "restore job must have fixed name pg-restore"
  [[ -z "$(git status --porcelain 2>/dev/null || true)" ]] || warn "checkout has uncommitted changes; ArgoCD deploys GitHub main"
  kubectl version >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
  CTX=$(kubectl config current-context)
  local nodes mem; nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  mem=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || true)
  log "cluster context: $CTX ($nodes node(s))"
  if [[ "$mem" =~ ^([0-9]+)Ki$ ]] && (( BASH_REMATCH[1]/1048576<7 )); then warn "node has under 7 GiB allocatable memory"; fi
  if (( FORCE==0 )) && { exists get applications.argoproj.io n8n -n argocd || exists get cluster.postgresql.cnpg.io n8n-db -n n8n; }; then die "cluster already runs n8n; use --force only if sure"; fi
  fetch_keys
}

print_plan() {
  cat <<EOF

PLAN for cluster '$CTX'
  controller  restore $KEY_COUNT sealing keys and install Sealed Secrets ($SEALED_SECRETS_INSTALL)
  argocd      install ArgoCD $ARGOCD_VERSION
  monitoring  install kube-prometheus-stack $KPS_VERSION
  platform    install cnpg-operator, keda, vpa, metrics-server
  base        apply redis-ha + n8n-base, then suspend backup CronJobs
  verify      verify secrets, encryption key, and Postgres
  restore     restore dump '$DUMP_KEY' from S3
  n8n         start n8n and root app
  finish      resume backups and run verification backup
EOF
}
confirm() { (( ASSUME_YES )) && return 0; [[ -t 0 ]] || die "not interactive: pass --yes"; local a; read -r -p "Type the cluster context name ($CTX) to continue: " a; [[ "$a" == "$CTX" ]] || die "confirmation did not match"; }

step_controller() {
  banner controller "restore Sealed Secrets keys and install controller"
  kubectl apply -f "$WORK/sealing-keys.json"
  if [[ "$SEALED_SECRETS_INSTALL" == helm ]]; then
    helm repo add sealed-secrets "${SEALED_SECRETS_HELM_REPO:-https://bitnami-labs.github.io/sealed-secrets}" --force-update >/dev/null
    helm upgrade --install sealed-secrets-controller sealed-secrets/sealed-secrets --version "$SEALED_SECRETS_CHART_VERSION" -n "$SS_NS" --set-string fullnameOverride="$SS_DEPLOY" --wait --timeout 5m
  else
    local v="${SEALED_SECRETS_VERSION#v}"
    kubectl apply -f "https://github.com/bitnami/sealed-secrets/releases/download/v${v}/controller.yaml"
  fi
  kubectl -n "$SS_NS" rollout status "deploy/$SS_DEPLOY" --timeout="$(scaled 300)s"
  local n; n=$(kubectl -n "$SS_NS" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l | tr -d ' ')
  (( n>=KEY_COUNT )) || die "controller sees $n keys, expected $KEY_COUNT"
}
step_argocd() {
  banner argocd "install ArgoCD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply --server-side --force-conflicts -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION#v}/manifests/install.yaml"
  must_wait "ArgoCD CRD" 120 3 exists get crd applications.argoproj.io
  kubectl -n argocd wait --for=condition=Available deploy --all --timeout="$(scaled 600)s"
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout="$(scaled 300)s"
  if [[ -n "$ARGOCD_REPO_SSH_KEY" ]]; then
    local url; url=$(grep -h -m1 'repoURL: git@' bootstrap/root.yaml | awk '{print $2}')
    kubectl -n argocd create secret generic repo-n8n-setup --from-literal=type=git --from-literal=url="$url" --from-file=sshPrivateKey="$ARGOCD_REPO_SSH_KEY" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n argocd label secret repo-n8n-setup argocd.argoproj.io/secret-type=repository --overwrite
  fi
}
step_monitoring() {
  banner monitoring "install kube-prometheus-stack $KPS_VERSION"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  local args=()
  if [[ -r "$MONITORING_VALUES" ]]; then args+=(-f "$MONITORING_VALUES"); else warn "no monitoring values found; disabling control-plane scrapes"; args+=(--set kubeControllerManager.enabled=false --set kubeScheduler.enabled=false --set kubeEtcd.enabled=false --set kubeProxy.enabled=false); fi
  if [[ -n "$ALERTMANAGER_VALUES" ]]; then [[ -r "$ALERTMANAGER_VALUES" ]] || die "ALERTMANAGER_VALUES not readable"; args+=(-f "$ALERTMANAGER_VALUES"); else warn "Alertmanager will have no email receiver"; fi
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" -n monitoring --create-namespace "${args[@]}" --wait --timeout "$(scaled 900)s"
}
step_platform() {
  banner platform "install platform operators"
  local app; for app in cnpg-operator keda vpa metrics-server; do kubectl apply -f "argocd/apps/$app.yaml"; done
  for app in cnpg-operator keda vpa metrics-server; do must_wait "Application $app Healthy/Synced" 900 10 app_ready "$app"; done
}
freeze_backups() {
  must_wait "CronJob pg-backup exists" 600 1 exists -n n8n get cronjob pg-backup
  must_wait "CronJob pg-backup-to-s3 exists" 600 1 exists -n n8n get cronjob pg-backup-to-s3
  kubectl -n n8n patch cronjob pg-backup -p '{"spec":{"suspend":true}}'
  kubectl -n n8n patch cronjob pg-backup-to-s3 -p '{"spec":{"suspend":true}}'
  [[ "$(kubectl -n n8n get cronjob pg-backup -o jsonpath='{.spec.suspend}')" == true && "$(kubectl -n n8n get cronjob pg-backup-to-s3 -o jsonpath='{.spec.suspend}')" == true ]] || die "could not suspend backup CronJobs"
  ok "backups frozen"
}
step_base() {
  banner base "apply base apps, then suspend backups"
  kubectl create namespace redis-ha --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace n8n --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f argocd/apps/redis-ha.yaml; kubectl apply -f argocd/apps/n8n-base.yaml
  freeze_backups
}
step_verify() {
  banner verify "verify secrets, key, database, Redis"
  if ! wait_for "Secret n8n-secrets" 600 5 exists -n n8n get secret n8n-secrets; then kubectl get sealedsecret -A 2>&1 | head -20 || true; die "n8n-secrets missing; restored keys cannot decrypt Git secrets"; fi
  must_wait "all SealedSecrets Synced" 300 5 sealedsecrets_synced
  local s live; for s in s3-backup nginx-tls n8n-runner-token n8n-smtp-credentials redis-cluster-auth; do must_wait "Secret $s" 120 3 exists -n n8n get secret "$s"; done
  must_wait "redis-cluster-auth in redis-ha" 120 3 exists -n redis-ha get secret redis-cluster-auth
  live=$(kubectl -n n8n get secret n8n-secrets -o jsonpath='{.data.N8N_ENCRYPTION_KEY}')
  [[ "$live" == "$EXPECTED_KEY_B64" ]] || die "N8N_ENCRYPTION_KEY mismatch; restoring would make credentials unreadable"
  must_wait "Postgres cluster exists" 600 5 exists -n n8n get cluster.postgresql.cnpg.io n8n-db
  must_wait "Postgres cluster Ready" 1200 10 cluster_ready
  must_wait "Application redis-ha Healthy/Synced" 900 10 app_ready redis-ha
}
step_restore() {
  banner restore "restore $DUMP_KEY from S3"
  local tmp="$WORK/pg-restore-job.yaml"; cp ops/pg-restore-job.yaml "$tmp"
  if [[ "$DUMP_KEY" != latest ]]; then sed -i "s/{ name: DUMP_KEY, value: \"latest\" }/{ name: DUMP_KEY, value: \"$DUMP_KEY\" }/" "$tmp"; grep -q "value: \"$DUMP_KEY\"" "$tmp" || die "could not set DUMP_KEY"; fi
  kubectl -n n8n delete job pg-restore --ignore-not-found --wait=true; kubectl apply -f "$tmp"
  local deadline=$(( $(date +%s)+$(scaled 3600) ))
  until job_succeeded pg-restore; do
    if job_failed pg-restore; then kubectl -n n8n logs job/pg-restore -c fetch 2>&1 | tail -15 || true; kubectl -n n8n logs job/pg-restore -c restore 2>&1 | tail -25 || true; die "restore job failed"; fi
    (( $(date +%s)<deadline )) || die "restore job timed out"; sleep 5
  done
  kubectl -n n8n logs job/pg-restore -c fetch 2>&1 | grep -E 'Selected dump' || true
  kubectl -n n8n logs job/pg-restore -c restore 2>&1 | grep -E 'Archive|Restored:|RESTORE COMPLETE' || die "restore job did not report completion"
}
step_n8n() {
  banner n8n "start n8n on restored data"
  kubectl apply -f argocd/apps/n8n.yaml
  must_wait "Application n8n Healthy" 1200 10 app_healthy n8n
  local d; for d in n8n-main n8n-webhook-processor n8n-worker; do must_wait "Deployment $d available" 900 5 deploy_ready "$d"; done
  kubectl apply -f bootstrap/root.yaml
}
step_finish() {
  banner finish "resume backups and verify"
  kubectl -n n8n patch cronjob pg-backup -p '{"spec":{"suspend":false}}'
  kubectl -n n8n patch cronjob pg-backup-to-s3 -p '{"spec":{"suspend":false}}'
  local j="rebuild-verify-$(date +%s)"; kubectl -n n8n create job "$j" --from=cronjob/pg-backup
  if wait_for "verification backup $j" 300 5 job_succeeded "$j"; then kubectl -n n8n logs "job/$j" 2>&1 | tail -4 || true; else kubectl -n n8n logs "job/$j" 2>&1 | tail -15 || true; die "verification backup failed"; fi
  local secs=$(( $(date +%s)-START_EPOCH )); kubectl -n argocd get applications || true
  echo "REBUILD FINISHED (elapsed $((secs/60))m $((secs%60))s); key backup: $DATE; dump: $DUMP_KEY"
}

preflight
if (( PLAN_ONLY )); then print_plan; echo "--plan: nothing was changed."; exit 0; fi
print_plan; confirm
for s in "${STEPS[@]}"; do if should_run "$s"; then "step_$s"; else log "skipping $s (--from $FROM_STEP)"; fi; done
