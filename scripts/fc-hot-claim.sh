#!/usr/bin/env bash
# Hot claim on a running pool VM — MMDS + handoff FSM + reload-env + reseed (no FC restart).
# Usage: fc-hot-claim.sh <vm_config_dir> [new_hebrah.env]
set -euo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/fc-snapshot-lib.sh"
# shellcheck source=fc-snapshot-lib.sh
source "$LIB"

CONFIG_DIR="${1:?vm_config_dir required}"
NEW_ENV="${2:-$CONFIG_DIR/hebrah.env}"
SOCK="$CONFIG_DIR/firecracker.sock"
HEALTH_PORT="${HEBRAH_HEALTH_HOST_PORT:?HEBRAH_HEALTH_HOST_PORT required}"
GUEST_IP="${HEBRAH_GUEST_IP:-}"
HOST_TAP_IP="${HEBRAH_HOST_TAP_IP:-}"
TAP_NAME="${HEBRAH_TAP_NAME:-}"
ADMIN_PORT="${HEBRAH_ADMIN_PORT:-8091}"
FHIR_PORT="${HEBRAH_FHIR_HOST_PORT:-$((HEALTH_PORT + 4))}"

if [ ! -S "$SOCK" ]; then
  echo "firecracker.sock missing in $CONFIG_DIR" >&2
  exit 1
fi
if [ ! -f "$NEW_ENV" ]; then
  echo "hebrah.env missing: $NEW_ENV" >&2
  exit 1
fi

started=$SECONDS
fc_put_mmds "$SOCK" "$NEW_ENV"
if [ "$(readlink -f "$NEW_ENV")" != "$(readlink -f "$CONFIG_DIR/hebrah.env")" ]; then
  cp "$NEW_ENV" "$CONFIG_DIR/hebrah.env"
fi

INTERNAL_SECRET="${HEBRAH_INTERNAL_SECRET:-}"
if [ -z "$INTERNAL_SECRET" ] && grep -q '^HEBRAH_INTERNAL_SECRET=' "$NEW_ENV" 2>/dev/null; then
  INTERNAL_SECRET="$(grep '^HEBRAH_INTERNAL_SECRET=' "$NEW_ENV" | cut -d= -f2-)"
fi
auth_hdr=()
if [ -n "$INTERNAL_SECRET" ]; then
  auth_hdr=(-H "X-Hebrah-Internal-Secret: ${INTERNAL_SECRET}")
fi

admin_base() {
  if [ -n "$GUEST_IP" ]; then
    echo "http://${GUEST_IP}:${ADMIN_PORT}"
  else
    echo "http://127.0.0.1:${FHIR_PORT}"
  fi
}

admin_post() {
  local path="$1"
  local attempt
  local base
  local curl_iface=()
  base="$(admin_base)"
  if [ -n "$GUEST_IP" ]; then
    if [ -n "$TAP_NAME" ]; then
      curl_iface=(--interface "$TAP_NAME")
    elif [ -n "$HOST_TAP_IP" ]; then
      curl_iface=(--interface "$HOST_TAP_IP")
    fi
  fi
  for attempt in 1 2 3 4 5 6 7 8; do
    if curl -sf -X POST "${base}${path}" \
      -H "Content-Type: application/json" "${auth_hdr[@]}" "${curl_iface[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

admin_post "/admin/handoff-begin"
admin_post "/admin/reload-env"
admin_post "/admin/reseed"
admin_post "/admin/handoff-complete"

deadline=$((SECONDS + 10))
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -sf "http://127.0.0.1:${HEALTH_PORT}/health" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    elapsed=$((SECONDS - started))
    echo "hot_claim_ok wall=${elapsed}s"
    exit 0
  fi
  sleep 0.25
done
echo "hot_claim health timeout" >&2
exit 1
