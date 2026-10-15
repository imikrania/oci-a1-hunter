#!/usr/bin/env bash
# Push the values in ./oci.env plus the private key ./oci_api_key.pem
# into this repo's GitHub Actions secrets.
# Nothing is echoed; the values never appear in the shell history or argv.
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ENV_FILE="${2:-oci.env}"
KEY_FILE="${3:-oci_api_key.pem}"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy oci.env.example and fill it in)"; exit 1; }
[ -f "$KEY_FILE" ] || { echo "missing $KEY_FILE (your OCI API private key, .pem)"; exit 1; }

echo "repo: $REPO"

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"                      # tolerate CRLF from Windows editors
  case "$line" in ''|'#'*) continue ;; esac
  key="${line%%=*}"
  val="${line#*=}"                          # keeps any later '=' (ssh keys, etc.)
  [ -n "$key" ] || continue
  printf '%s' "$val" | gh secret set "$key" --repo "$REPO"
  echo "  set $key"
done < "$ENV_FILE"

gh secret set OCI_PRIVATE_KEY --repo "$REPO" < "$KEY_FILE"
echo "  set OCI_PRIVATE_KEY"

echo
echo "done. verify with: gh secret list --repo $REPO"
