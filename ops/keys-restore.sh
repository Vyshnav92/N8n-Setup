#!/usr/bin/env bash
# Restores the Sealed Secrets private keys from the age-encrypted backup on Google Drive
# into the cluster, then restarts the Sealed Secrets controller so it loads them.
#
#   AGE_IDENTITY=~/age-key.txt ./ops/keys-restore.sh                              newest backup
#   AGE_IDENTITY=~/age-key.txt ./ops/keys-restore.sh sealing-keys-20261024.json.age   a specific one
#   DRY_RUN=1 AGE_IDENTITY=... ./ops/keys-restore.sh                              validate only, change nothing
#
# Run it on a new cluster AFTER the Sealed Secrets controller is installed and BEFORE ArgoCD syncs.
# The age private key never enters the cluster; decryption happens on this machine.
# Needs: kubectl, jq, age, rclone (with a "gdrive" remote).
set -euo pipefail

: "${AGE_IDENTITY:?Set AGE_IDENTITY to the path of your age identity (private key) file}"
[[ -r "$AGE_IDENTITY" ]] || { echo "ERROR: cannot read AGE_IDENTITY file: $AGE_IDENTITY" >&2; exit 1; }

remote="gdrive:n8n-dr"
ns="${SS_NAMESPACE:-kube-system}"

for tool in kubectl jq age rclone; do
  command -v "$tool" >/dev/null || { echo "ERROR: '$tool' is not installed" >&2; exit 1; }
done

umask 077
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

file="${1:-}"
if [[ -z "$file" ]]; then
  file=$(rclone lsf "$remote" --files-only |
    grep -E '^sealing-keys-[0-9]{8}\.json\.age$' | sort | tail -n 1 || true)
  [[ -n "$file" ]] || { echo "ERROR: no sealing-keys backup found in $remote" >&2; exit 1; }
fi
[[ "$file" =~ ^sealing-keys-[0-9]{8}\.json\.age$ ]] || {
  echo "ERROR: expected a file named sealing-keys-YYYYMMDD.json.age, got: $file" >&2
  exit 1
}

echo "Cluster : $(kubectl config current-context)"
echo "Backup  : $file"

rclone copyto "$remote/$file" "$out/keys.age"
age -d -i "$AGE_IDENTITY" -o "$out/keys.json" "$out/keys.age"

# Refuse anything that is not a non-empty list of key secrets for the right namespace.
jq -e --arg ns "$ns" '
  .kind == "List" and (.items | length) > 0 and
  all(.items[]; .metadata.namespace == $ns and (.data["tls.crt"] != null) and (.data["tls.key"] != null))
' "$out/keys.json" >/dev/null || {
  echo "ERROR: backup is empty or is not a valid Sealed Secrets key export" >&2
  exit 1
}
echo "Keys in backup: $(jq '.items | length' "$out/keys.json")"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  kubectl apply --dry-run=server -f "$out/keys.json"
  echo "DRY RUN complete. Nothing was changed."
  exit 0
fi

kubectl apply -f "$out/keys.json"

# Restart the controller so it loads the restored keys.
controller=$(kubectl -n "$ns" get deploy -o name | grep -i sealed || true)
if [[ "$(printf '%s\n' "$controller" | grep -c .)" -eq 1 ]]; then
  kubectl -n "$ns" rollout restart "$controller"
  kubectl -n "$ns" rollout status "$controller" --timeout=120s
else
  echo "WARNING: could not identify exactly one Sealed Secrets controller Deployment in $ns." >&2
  echo "Restart it yourself: kubectl -n $ns rollout restart deploy/<controller-name>" >&2
fi

echo "Keys now in cluster: $(kubectl -n "$ns" get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l)"
echo "DONE. Check that your sealed secrets decrypt: kubectl get sealedsecret -A"
echo "Then run ./ops/keys-backup.sh again, so any key the new controller generated is backed up too."
