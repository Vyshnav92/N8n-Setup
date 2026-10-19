#!/usr/bin/env bash
set -euo pipefail
: "${AGE_IDENTITY:?Set AGE_IDENTITY to your age identity file}"
file=${1:?Usage: keys-restore.sh sealing-keys-DATE.json.age}

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
chmod 700 "$out"
umask 077

rclone copyto "gdrive:n8n-dr/$file" "$out/keys.age"
age -d -i "$AGE_IDENTITY" -o "$out/keys.json" "$out/keys.age"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  kubectl apply --dry-run=server -f "$out/keys.json"
else
  echo "Refusing live restore. Set DRY_RUN=1 to validate safely."
  exit 1
fi
