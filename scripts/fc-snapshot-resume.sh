#!/usr/bin/env bash
# Resume a VM from golden blank.snapshot into HEBRAH_VM_CONFIG_DIR (no full guest boot).
# Requires launch-firecracker.sh snapshot mode env vars (same as orchestrator).
set -euo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/fc-snapshot-lib.sh"
# shellcheck source=fc-snapshot-lib.sh
source "$LIB"

GOLDEN_DIR="${HEBRAH_GOLDEN_DIR:?HEBRAH_GOLDEN_DIR required}"
CONFIG_DIR="${HEBRAH_VM_CONFIG_DIR:?HEBRAH_VM_CONFIG_DIR required}"
SNAP="${HEBRAH_SNAPSHOT_PATH:-$GOLDEN_DIR/blank.snapshot}"
MEM="${HEBRAH_MEM_PATH:-$GOLDEN_DIR/blank.mem}"

if [ ! -f "$SNAP" ] || [ ! -f "$MEM" ]; then
  echo "snapshot files missing: $SNAP $MEM" >&2
  exit 1
fi

export HEBRAH_LAUNCH_MODE=snapshot
export HEBRAH_SNAPSHOT_PATH="$SNAP"
export HEBRAH_MEM_PATH="$MEM"

bash "$GOLDEN_DIR/launch.sh"
