#!/usr/bin/env bash
# Boot a smoke VM from golden, pause, and write blank.{snapshot,mem} into GOLDEN_DIR.
# Usage: fc-snapshot-create.sh <golden_dir> [work_vm_id]
set -euo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/fc-snapshot-lib.sh"
# shellcheck source=fc-snapshot-lib.sh
source "$LIB"

GOLDEN_DIR="${1:?golden_dir required}"
WORK_VM_ID="${2:-pool-snapshot-smoke}"
WORK_DIR="${HEBRAH_SNAPSHOT_WORK_DIR:-/tmp/hebrah-fc-snapshot-$$}"
SNAP_OUT="$GOLDEN_DIR/blank.snapshot"
MEM_OUT="$GOLDEN_DIR/blank.mem"

if [ ! -x "$GOLDEN_DIR/launch.sh" ]; then
  echo "launch.sh missing in $GOLDEN_DIR" >&2
  exit 1
fi

if [ ! -c /dev/kvm ]; then
  echo "KVM required for snapshot capture (/dev/kvm missing)" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

HEALTH_PORT="${HEBRAH_SNAPSHOT_SMOKE_HEALTH_PORT:-19990}"
WB_PORT=$((HEALTH_PORT + 1))
HL7_PORT=$((HEALTH_PORT + 2))
MLLP_PORT=$((HEALTH_PORT + 3))
FHIR_PORT=$((HEALTH_PORT + 4))
GUEST_IP="${HEBRAH_SNAPSHOT_GUEST_IP:-10.200.250.2}"

flush_dnat_dport() {
  local host_port="$1" chain line
  for chain in OUTPUT PREROUTING; do
    while true; do
      line="$(sudo iptables -t nat -L "$chain" -n --line-numbers 2>/dev/null \
        | awk -v p="dpt:${host_port}" '$0 ~ p && /DNAT/ { print $1; exit }' || true)"
      [ -z "$line" ] && break
      sudo iptables -t nat -D "$chain" "$line" 2>/dev/null || break
    done
  done
}

for offset in 0 1 2 3 4; do
  flush_dnat_dport $((HEALTH_PORT + offset))
done

INTERNAL_SECRET="${HEBRAH_INTERNAL_SECRET:-}"
cat >"$WORK_DIR/hebrah.env" <<EOF
HEBRAH_VM_ID=${WORK_VM_ID}
HEBRAH_ORG_ID=__hebrah_pool__
HEBRAH_CONNECTION_ID=pool-snapshot-smoke
HEBRAH_ENVIRONMENT=sandbox
HEBRAH_API_URL=http://127.0.0.1:8000
HEBRAH_EHR_VENDOR=Epic
HEBRAH_EHR_MODEL_VERSION=1.0.0
HEBRAH_SYNTHETIC_EHR_SEED=0
HEBRAH_SYNTHETIC_EHR_PORT=8090
EOF
if [ -n "$INTERNAL_SECRET" ]; then
  echo "HEBRAH_INTERNAL_SECRET=$INTERNAL_SECRET" >>"$WORK_DIR/hebrah.env"
fi

export HEBRAH_VM_CONFIG_DIR="$WORK_DIR"
export HEBRAH_VM_PIDFILE="$WORK_DIR/pid"
export HEBRAH_VM_LOGFILE="$WORK_DIR/vm.log"
export HEBRAH_HEALTH_HOST_PORT="$HEALTH_PORT"
export HEBRAH_WRITEBACK_HOST_PORT="$WB_PORT"
export HEBRAH_HL7_HOST_PORT="$HL7_PORT"
export HEBRAH_MLLP_HOST_PORT="$MLLP_PORT"
export HEBRAH_FHIR_HOST_PORT="$FHIR_PORT"
export HEBRAH_GOLDEN_DIR="$GOLDEN_DIR"
export HEBRAH_LAUNCH_MODE=boot
export HEBRAH_TAP_NAME="hbsmoke$$"
export HEBRAH_GUEST_IP="$GUEST_IP"
export HEBRAH_HOST_TAP_IP="10.200.250.1"

echo "==> Booting smoke VM for snapshot capture ($WORK_VM_ID)"
bash "$GOLDEN_DIR/launch.sh"

if ! poll_health_port_fast "$HEALTH_PORT" "${HEBRAH_SNAPSHOT_BOOT_TIMEOUT_SEC:-120}"; then
  echo "smoke VM health timeout — see $WORK_DIR/vm.log" >&2
  tail -30 "$WORK_DIR/vm.log" >&2 || true
  exit 1
fi

HOST_TAP_IP="${HEBRAH_HOST_TAP_IP:-10.200.250.1}"
TAP_NAME="${HEBRAH_TAP_NAME:-hbsmoke$$}"
SOCK="$WORK_DIR/firecracker.sock"
if [ -S "$SOCK" ] && [ -n "$INTERNAL_SECRET" ]; then
  fc_put_mmds "$SOCK" "$WORK_DIR/hebrah.env"
  poll_reload_env_tap "$GUEST_IP" "$HOST_TAP_IP" "$TAP_NAME" "$INTERNAL_SECRET" || {
    echo "smoke VM reload-env tap timeout — see $WORK_DIR/vm.log" >&2
    tail -30 "$WORK_DIR/vm.log" >&2 || true
    exit 1
  }
fi
if ! poll_admin_tap "$GUEST_IP" "$HOST_TAP_IP" "$TAP_NAME" "$INTERNAL_SECRET"; then
  echo "smoke VM admin :8091 tap timeout — see $WORK_DIR/vm.log" >&2
  tail -30 "$WORK_DIR/vm.log" >&2 || true
  exit 1
fi
admin_post_tap "$GUEST_IP" "$HOST_TAP_IP" "$TAP_NAME" "$INTERNAL_SECRET" "/admin/handoff-complete" || true

SOCK="$WORK_DIR/firecracker.sock"
echo "==> Pausing VM and creating snapshot"
fc_patch_vm_state "$SOCK" Paused
rm -f "$SNAP_OUT" "$MEM_OUT"
fc_create_snapshot "$SOCK" "$SNAP_OUT" "$MEM_OUT"

PID="$(cat "$WORK_DIR/pid" 2>/dev/null || true)"
if [ -n "$PID" ]; then
  kill "$PID" 2>/dev/null || true
fi

MEM_MB="$(du -m "$MEM_OUT" 2>/dev/null | awk '{print $1}' || echo 0)"
python3 - "$GOLDEN_DIR/manifest.json" "$MEM_MB" <<'PY'
import json, sys
path, mem_mb = sys.argv[1], int(sys.argv[2] or 0)
with open(path, encoding="utf-8") as f:
    m = json.load(f)
m["snapshot"] = {
    "snapshot_path": "blank.snapshot",
    "mem_path": "blank.mem",
    "mem_mb": mem_mb,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "==> Snapshot OK: $SNAP_OUT ($MEM_MB MiB mem)"
