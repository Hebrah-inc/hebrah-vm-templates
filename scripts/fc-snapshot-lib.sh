#!/usr/bin/env bash
# Shared Firecracker API helpers for snapshot create/resume scripts.
set -euo pipefail

fc_curl() {
  local sock="$1"
  shift
  curl -sS --unix-socket "$sock" "$@"
}

fc_patch_vm_state() {
  local sock="$1" state="$2"
  fc_curl "$sock" -X PATCH "http://localhost/vm" \
    -H "Content-Type: application/json" \
    -d "{\"state\":\"$state\"}" >/dev/null
}

fc_put_mmds() {
  local sock="$1" env_file="$2"
  local payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hebrah.env": open(sys.argv[1], encoding="utf-8").read()}))' "$env_file")"
  fc_curl "$sock" -X PUT "http://localhost/mmds" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null
}

fc_create_snapshot() {
  local sock="$1" snap_path="$2" mem_path="$3"
  fc_curl "$sock" -X PUT "http://localhost/snapshot/create" \
    -H "Content-Type: application/json" \
    -d "{\"snapshot_path\":\"$snap_path\",\"mem_file_path\":\"$mem_path\"}" >/dev/null
}

fc_load_snapshot() {
  local sock="$1" snap_path="$2" mem_path="$3"
  fc_curl "$sock" -X PUT "http://localhost/snapshot/load" \
    -H "Content-Type: application/json" \
    -d "{\"snapshot_path\":\"$snap_path\",\"mem_backend\":{\"backend_path\":\"$mem_path\",\"backend_type\":\"File\"},\"track_dirty_pages\":false}" >/dev/null
}

fc_wait_sock() {
  local sock="$1" max_ms="${2:-2000}"
  local waited=0
  while [ "$waited" -lt "$max_ms" ]; do
    if [ -S "$sock" ]; then
      echo "$waited"
      return 0
    fi
    sleep 0.02
    waited=$((waited + 20))
  done
  return 1
}

poll_health_port() {
  local port="$1" timeout_sec="${2:-120}"
  local interval_ms="${3:-1000}"
  local deadline=$((SECONDS + timeout_sec))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sf --connect-timeout 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$interval_ms" -le 250 ]; then
      sleep 0.25
    else
      sleep 1
    fi
  done
  return 1
}

poll_health_port_fast() {
  poll_health_port "$1" "${2:-60}" 250
}
