#!/usr/bin/env bash
# Firecracker golden launch — tap + DNAT + MMDS (used by sidecar-base-fc launch.sh).
# Env (set by orchestrator golden_qemu/firecracker backend):
#   HEBRAH_VM_CONFIG_DIR, HEBRAH_VM_PIDFILE, HEBRAH_VM_LOGFILE
#   HEBRAH_HEALTH_HOST_PORT (+ optional WRITEBACK/HL7/MLLP/FHIR host ports)
#   HEBRAH_TAP_NAME, HEBRAH_GUEST_IP, HEBRAH_HOST_TAP_IP (optional)
set -euo pipefail

GOLDEN_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$GOLDEN_DIR/runner/bin/microvm-run"
if [ ! -x "$RUNNER" ]; then
  RUNNER="$(find "$GOLDEN_DIR/runner/bin" -maxdepth 1 -type f -perm -111 2>/dev/null | head -1 || true)"
fi
if [ ! -x "$RUNNER" ]; then
  echo "microvm runner not found under $GOLDEN_DIR/runner/bin" >&2
  exit 1
fi

CONFIG_DIR="${HEBRAH_VM_CONFIG_DIR:?HEBRAH_VM_CONFIG_DIR required}"
LOGFILE="${HEBRAH_VM_LOGFILE:-$CONFIG_DIR/vm.log}"
PIDFILE="${HEBRAH_VM_PIDFILE:?HEBRAH_VM_PIDFILE required}"
TAP_NAME="${HEBRAH_TAP_NAME:-hb-fc0}"
GUEST_IP="${HEBRAH_GUEST_IP:-10.200.10.2}"
HOST_TAP_IP="${HEBRAH_HOST_TAP_IP:-10.200.10.1}"
HEALTH_PORT="${HEBRAH_HEALTH_HOST_PORT:?HEBRAH_HEALTH_HOST_PORT required}"
WB_PORT="${HEBRAH_WRITEBACK_HOST_PORT:-$((HEALTH_PORT + 1))}"
HL7_PORT="${HEBRAH_HL7_HOST_PORT:-$((HEALTH_PORT + 2))}"
MLLP_PORT="${HEBRAH_MLLP_HOST_PORT:-$((HEALTH_PORT + 3))}"
FHIR_PORT="${HEBRAH_FHIR_HOST_PORT:-$((HEALTH_PORT + 4))}"
HEBRAH_LAUNCH_MODE="${HEBRAH_LAUNCH_MODE:-boot}"
SNAPSHOT_PATH="${HEBRAH_SNAPSHOT_PATH:-}"
MEM_PATH="${HEBRAH_MEM_PATH:-}"
SOCK="$CONFIG_DIR/firecracker.sock"
RUNTIME_CFG="$CONFIG_DIR/firecracker.json"

mkdir -p "$CONFIG_DIR" "$(dirname "$LOGFILE")"
cd "$CONFIG_DIR"

RUN_REAL="$(readlink -f "$RUNNER" 2>/dev/null || echo "$RUNNER")"
FC_BIN="$(grep -oE '/nix/store/[^[:space:]]+/bin/firecracker' "$RUN_REAL" | head -1 || true)"
BASE_CFG=""
for cand in $(grep -oE '/nix/store/[^[:space:]]+\.json' "$RUN_REAL" || true); do
  if grep -q 'boot-source\|network-interfaces' "$cand" 2>/dev/null; then
    BASE_CFG="$cand"
    break
  fi
done

if [ -z "$FC_BIN" ] || [ ! -x "$FC_BIN" ]; then
  echo "firecracker binary not found in $RUN_REAL" >&2
  exit 1
fi
if [ -z "$BASE_CFG" ] || [ ! -f "$BASE_CFG" ]; then
  echo "firecracker config JSON not found in $RUN_REAL" >&2
  exit 1
fi

dnat_del() {
  local host_port="$1" guest_port="$2"
  sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$host_port" \
    -j DNAT --to-destination "${GUEST_IP}:${guest_port}" 2>/dev/null || true
  sudo iptables -t nat -D PREROUTING -p tcp --dport "$host_port" \
    -j DNAT --to-destination "${GUEST_IP}:${guest_port}" 2>/dev/null || true
}

# Drop every DNAT rule for a host dport (any destination). Prevents stale/colliding
# rules from an earlier VM whose health+N overlapped this port.
flush_dnat_dport() {
  local host_port="$1" chain line
  for chain in OUTPUT PREROUTING; do
    while true; do
      line="$(sudo iptables -t nat -L "$chain" -n --line-numbers 2>/dev/null \
        | awk -v p="dpt:${host_port}" '$0 ~ p && /DNAT/ { print $1; exit }')"
      [ -z "$line" ] && break
      sudo iptables -t nat -D "$chain" "$line" 2>/dev/null || break
    done
  done
}

dnat_port_in_use() {
  local host_port="$1" chain
  for chain in OUTPUT PREROUTING; do
    if sudo iptables -t nat -L "$chain" -n 2>/dev/null | grep -q "dpt:${host_port}.*DNAT"; then
      return 0
    fi
  done
  return 1
}

cleanup_net() {
  dnat_del "$HEALTH_PORT" 8080
  dnat_del "$WB_PORT" 8082
  dnat_del "$HL7_PORT" 8083
  dnat_del "$MLLP_PORT" 2575
  dnat_del "$FHIR_PORT" 8090
  sudo iptables -t nat -D POSTROUTING -o "$TAP_NAME" -j MASQUERADE 2>/dev/null || true
  sudo iptables -D FORWARD -i "$TAP_NAME" -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -o "$TAP_NAME" -j ACCEPT 2>/dev/null || true
  sudo ip link del "$TAP_NAME" 2>/dev/null || true
}

cleanup_net

# microvm.nix volumes (var.img) — skip on snapshot resume (fresh per VM).
VAR_IMG="$CONFIG_DIR/var.img"
VAR_SIZE_MB="${HEBRAH_FC_VAR_SIZE_MB:-256}"
if [ "$HEBRAH_LAUNCH_MODE" != "snapshot" ]; then
if [ ! -e "$VAR_IMG" ]; then
  truncate -s "${VAR_SIZE_MB}M" "$VAR_IMG"
  MKFS="$(command -v mkfs.ext4 || true)"
  if [ -z "$MKFS" ]; then
    for cand in /usr/sbin/mkfs.ext4 /sbin/mkfs.ext4; do
      if [ -x "$cand" ]; then MKFS="$cand"; break; fi
    done
  fi
  if [ -z "$MKFS" ]; then
    echo "mkfs.ext4 not found — install e2fsprogs" >&2
    exit 1
  fi
  "$MKFS" -F -L var "$VAR_IMG" >>"$LOGFILE" 2>&1
fi
fi

if [ "$HEBRAH_LAUNCH_MODE" = "snapshot" ]; then
  GOLDEN_VAR="${HEBRAH_GOLDEN_DIR:-$GOLDEN_DIR}/var.img"
  if [ ! -e "$VAR_IMG" ] && [ -f "$GOLDEN_VAR" ]; then
    cp "$GOLDEN_VAR" "$VAR_IMG"
  fi
  if [ ! -e "$VAR_IMG" ]; then
    truncate -s "${VAR_SIZE_MB}M" "$VAR_IMG"
    MKFS="$(command -v mkfs.ext4 || true)"
    if [ -z "$MKFS" ]; then
      for cand in /usr/sbin/mkfs.ext4 /sbin/mkfs.ext4; do
        if [ -x "$cand" ]; then MKFS="$cand"; break; fi
      done
    fi
    if [ -n "$MKFS" ]; then
      "$MKFS" -F -L var "$VAR_IMG" >>"$LOGFILE" 2>&1
    fi
  fi
  if [ -z "$SNAPSHOT_PATH" ] || [ -z "$MEM_PATH" ]; then
    GOLDEN_SNAP="${HEBRAH_GOLDEN_DIR:-$GOLDEN_DIR}/blank.snapshot"
    GOLDEN_MEM="${HEBRAH_GOLDEN_DIR:-$GOLDEN_DIR}/blank.mem"
    SNAPSHOT_PATH="${SNAPSHOT_PATH:-$GOLDEN_SNAP}"
    MEM_PATH="${MEM_PATH:-$GOLDEN_MEM}"
  fi
  if [ ! -f "$SNAPSHOT_PATH" ] || [ ! -f "$MEM_PATH" ]; then
    echo "snapshot mode requires blank.snapshot and blank.mem (got $SNAPSHOT_PATH)" >&2
    exit 1
  fi
fi

sudo ip tuntap add dev "$TAP_NAME" mode tap user "$(id -un)" vnet_hdr
sudo ip addr add "${HOST_TAP_IP}/24" dev "$TAP_NAME"
sudo ip link set "$TAP_NAME" up
sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w "net.ipv4.conf.${TAP_NAME}.proxy_arp=1" >/dev/null || true

# Patch tap name, unique MAC, and kernel IP autoconfig (empty device = first iface).
python3 - "$BASE_CFG" "$RUNTIME_CFG" "$TAP_NAME" "$GUEST_IP" "$HOST_TAP_IP" <<'PY'
import hashlib, json, re, sys
src, dst, tap, guest_ip, host_ip = sys.argv[1:6]
cfg = json.loads(open(src, encoding="utf-8").read())
# Stable locally-administered MAC from tap name (02:xx:…).
digest = hashlib.sha256(tap.encode()).digest()
mac = "02:%02x:%02x:%02x:%02x:%02x" % tuple(digest[:5])
for iface in cfg.get("network-interfaces") or []:
    iface["iface_id"] = tap
    iface["host_dev_name"] = tap
    iface["guest_mac"] = mac
mmds = cfg.setdefault("mmds-config", {})
mmds["version"] = mmds.get("version") or "V1"
mmds["ipv4_address"] = mmds.get("ipv4_address") or "169.254.169.254"
mmds["network_interfaces"] = [tap]
boot = cfg.setdefault("boot-source", {})
args = boot.get("boot_args") or ""
args = re.sub(r"\bip=[^\s]*", "", args).strip()
# Empty device field: apply to first network interface (eth0 / ens* / enp*).
ip_cfg = f"ip={guest_ip}::{host_ip}:255.255.255.0:::"
boot["boot_args"] = f"{args} {ip_cfg}".strip()
open(dst, "w", encoding="utf-8").write(json.dumps(cfg, indent=2))
PY

dnat_add() {
  local host_port="$1" guest_port="$2"
  if [ "${HEBRAH_POOL_REFILL:-}" = "1" ] && ! dnat_port_in_use "$host_port"; then
    :
  else
    flush_dnat_dport "$host_port"
  fi
  # Local-on-host health checks (orchestrator on Ubuntu)
  sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport "$host_port" \
    -j DNAT --to-destination "${GUEST_IP}:${guest_port}"
  # Remote clients (Mac via Tailscale) — PREROUTING reaches guest FHIR/health ports
  sudo iptables -t nat -A PREROUTING -p tcp --dport "$host_port" \
    -j DNAT --to-destination "${GUEST_IP}:${guest_port}"
}
dnat_add "$HEALTH_PORT" 8080
dnat_add "$WB_PORT" 8082
dnat_add "$HL7_PORT" 8083
dnat_add "$MLLP_PORT" 2575
dnat_add "$FHIR_PORT" 8090
sudo iptables -C FORWARD -i "$TAP_NAME" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -i "$TAP_NAME" -j ACCEPT
sudo iptables -C FORWARD -o "$TAP_NAME" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -o "$TAP_NAME" -j ACCEPT
sudo iptables -t nat -C POSTROUTING -o "$TAP_NAME" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -o "$TAP_NAME" -j MASQUERADE

rm -f "$SOCK"
# Firecracker >=1.13 (microvm.nix) expects PCI virtio; without this, virtio-mmio probes EBUSY.
nohup "$FC_BIN" --config-file "$RUNTIME_CFG" --api-sock "$SOCK" --enable-pci >"$LOGFILE" 2>&1 &
echo $! >"$PIDFILE"

sock_wait_ms=0
for _ in $(seq 1 100); do
  if [ -S "$SOCK" ]; then
    break
  fi
  sleep 0.02
  sock_wait_ms=$((sock_wait_ms + 20))
done
echo "fc_sock_ready_ms=${sock_wait_ms}" >>"$LOGFILE"

if [ "$HEBRAH_LAUNCH_MODE" = "snapshot" ] && [ -S "$SOCK" ]; then
  echo "fc_snapshot_load path=$SNAPSHOT_PATH" >>"$LOGFILE"
  fc_curl_snap() {
    curl -sS --unix-socket "$SOCK" "$@"
  }
  fc_curl_snap -X PUT "http://localhost/snapshot/load" \
    -H "Content-Type: application/json" \
    -d "{\"snapshot_path\":\"$SNAPSHOT_PATH\",\"mem_backend\":{\"backend_path\":\"$MEM_PATH\",\"backend_type\":\"File\"},\"track_dirty_pages\":false}" \
    >>"$LOGFILE" 2>&1
  fc_curl_snap -X PATCH "http://localhost/vm" \
    -H "Content-Type: application/json" \
    -d '{"state":"Resumed"}' >>"$LOGFILE" 2>&1
  echo "fc_snapshot_resumed" >>"$LOGFILE"
fi

if [ -f "$CONFIG_DIR/hebrah.env" ] && [ -S "$SOCK" ]; then
  MMDS_JSON="$(python3 -c 'import json,sys; print(json.dumps({"hebrah.env": open(sys.argv[1], encoding="utf-8").read()}))' "$CONFIG_DIR/hebrah.env")"
  curl -sS --unix-socket "$SOCK" -X PUT "http://localhost/mmds" \
    -H "Content-Type: application/json" \
    -d "$MMDS_JSON" >>"$LOGFILE" 2>&1 || true
fi
