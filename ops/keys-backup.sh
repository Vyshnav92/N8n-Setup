#!/usr/bin/env bash
set -euo pipefail
: "${AGE_RECIPIENT:?Set AGE_RECIPIENT to your age public key}"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
umask 077
d=$(date -u +%Y%m%d)

# Export all Sealed Secrets private keys
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o json |
  jq 'del(.items[].metadata.resourceVersion,
          .items[].metadata.uid,
          .items[].metadata.creationTimestamp,
          .items[].metadata.managedFields)' \
  > "$out/sealing-keys.json"

# Export n8n encryption-key Secret
kubectl get secret n8n-secrets -n n8n -o json |
  jq '{apiVersion,kind,type,metadata:{name:.metadata.name,namespace:.metadata.namespace},data}' \
  > "$out/n8n-secrets.json"

for f in sealing-keys n8n-secrets; do
  age -r "$AGE_RECIPIENT" \
    -o "$out/$f-$d.json.age" "$out/$f.json"
  rclone copyto "$out/$f-$d.json.age" \
    "gdrive:n8n-dr/$f-$d.json.age"
done

echo "Uploaded encrypted key backups for $d"
