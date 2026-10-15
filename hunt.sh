#!/usr/bin/env bash
# OCI A1 capacity hunter.
#   exit 0 = instance created, OR no capacity right now (retry next scheduled run)
#   exit 1 = fatal (missing config / authorization) - stop and read the log
# Requires the OCI CLI configured at ~/.oci/config, and these env vars:
#   OCI_TENANCY_OCID OCI_COMPARTMENT_OCID OCI_IMAGE_ID OCI_SUBNET_ID OCI_SSH_PUBLIC_KEY
# Optional: OCI_OCPUS (1) OCI_MEMORY_GB (6) OCI_SHAPE (VM.Standard.A1.Flex) OCI_DISPLAY_NAME (a1-hunter)

set -uo pipefail

say() { echo "[$(date -u +%H:%M:%S)] $*"; }

need() {
  if [ -z "${!1:-}" ]; then say "FATAL: $1 is not set"; exit 1; fi
}

need OCI_TENANCY_OCID
need OCI_COMPARTMENT_OCID
need OCI_IMAGE_ID
need OCI_SUBNET_ID
need OCI_SSH_PUBLIC_KEY

OCPUS="${OCI_OCPUS:-1}"
MEMORY_GB="${OCI_MEMORY_GB:-6}"
SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
NAME="${OCI_DISPLAY_NAME:-a1-hunter}"

say "shape=$SHAPE ocpus=$OCPUS memory=${MEMORY_GB}GB name=$NAME"

# --- 1. idempotency: do we already have one? -------------------------------
existing=$(oci compute instance list \
  --compartment-id "$OCI_COMPARTMENT_OCID" \
  --display-name "$NAME" \
  --all --output json 2>/dev/null \
  | python -c "import sys,json;d=json.load(sys.stdin).get('data',[]);print(sum(1 for i in d if i.get('lifecycle-state') not in ('TERMINATED','TERMINATING')))" 2>/dev/null \
  || echo 0)

if [ "${existing:-0}" -gt 0 ] 2>/dev/null; then
  say "already provisioned ($existing instance(s) named '$NAME') - nothing to do"
  exit 0
fi

# --- 2. availability domains ----------------------------------------------
mapfile -t ADS < <(oci iam availability-domain list \
  --compartment-id "$OCI_TENANCY_OCID" \
  --query 'data[*].name' --raw-output 2>/dev/null \
  | tr -d '[]"' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$')

if [ "${#ADS[@]}" -eq 0 ]; then
  say "FATAL: could not list availability domains - check credentials, tenancy OCID and region"
  exit 1
fi
say "availability domains: ${ADS[*]}"

shape_config="{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}"
metadata="{\"ssh_authorized_keys\": \"$OCI_SSH_PUBLIC_KEY\"}"

# --- 3. try to launch ------------------------------------------------------
# return 0 = launched, 1 = fatal, 2 = out of capacity, 3 = transient (retry)
try_ad() {
  local ad="$1" out rc
  out=$(oci compute instance launch \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --availability-domain "$ad" \
      --shape "$SHAPE" \
      --shape-config "$shape_config" \
      --image-id "$OCI_IMAGE_ID" \
      --subnet-id "$OCI_SUBNET_ID" \
      --assign-public-ip true \
      --display-name "$NAME" \
      --metadata "$metadata" 2>&1)
  rc=$?

  if [ $rc -eq 0 ]; then
    say "LAUNCHED in $ad"
    echo "$out"
    return 0
  fi

  case "$out" in
    *"Out of host capacity"*|*"out of host capacity"*|*OutOfHostCapacity*|*OutOfCapacity*)
      return 2 ;;
    *TooManyRequests*|*"429"*|*InternalError*|*"500"*|*"502"*|*"503"*|*Timeout*|*timeout*)
      return 3 ;;
    *)
      say "FATAL error in $ad:"
      echo "$out" >&2
      return 1 ;;
  esac
}

for ad in "${ADS[@]}"; do
  for attempt in 1 2 3; do
    try_ad "$ad"; rc=$?
    if [ $rc -eq 0 ]; then exit 0; fi
    if [ $rc -eq 2 ]; then say "$ad: out of host capacity"; break; fi
    if [ $rc -eq 1 ]; then exit 1; fi
    say "$ad: transient error (attempt $attempt) - backing off"
    sleep $(( attempt * 20 ))
  done
done

say "no capacity in any availability domain this cycle - will retry on the next run"
exit 0
