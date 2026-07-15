#!/usr/bin/env python3
"""Sidecar health agent — HTTP :8080 and health.json on shared config dir."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        data[key.strip()] = value.strip()
    return data


def write_health(config_dir: Path, payload: dict) -> bool:
    text = json.dumps(payload, indent=2) + "\n"
    path = config_dir / "health.json"
    try:
        # Shell redirect is more reliable than Python buffered writes on some 9p mounts.
        proc = subprocess.run(
            ["/bin/sh", "-c", "cat > \"$1\"", "sh", str(path)],
            input=text,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            return True
        path.write_text(text)
        return True
    except OSError as exc:
        print(f"hebrah-sidecar-health: write failed for {path}: {exc}", file=sys.stderr)
        return False


def persist_health(config_dir: Path, state_dir: Path, payload: dict) -> bool:
    if write_health(config_dir, payload):
        return True
    if write_health(state_dir, payload):
        print(
            f"hebrah-sidecar-health: wrote health.json to fallback {state_dir} only "
            f"({config_dir} not writable via 9p)",
            file=sys.stderr,
        )
        return True
    return False


def config_mount_ready(config_dir: Path) -> bool:
    mount = Path("/proc/mounts")
    if mount.is_file():
        try:
            if f" {config_dir} " in mount.read_text():
                return True
        except OSError:
            pass
    return config_dir.is_dir() and os.access(config_dir, os.W_OK | os.X_OK)


def wait_for_config_mount(config_dir: Path, *, timeout_sec: float = 30.0) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if config_mount_ready(config_dir):
            return True
        time.sleep(0.5)
    return config_mount_ready(config_dir)


def synthetic_ehr_ready(config_dir: Path) -> bool:
    env = load_env(config_dir / "hebrah.env")
    port = int(env.get("HEBRAH_SYNTHETIC_EHR_PORT", "8090"))
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/metadata", timeout=2) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def build_payload(config_dir: Path) -> dict:
    env_file = config_dir / "hebrah.env"
    env = load_env(env_file)
    vm_id = env.get("HEBRAH_VM_ID", os.environ.get("HEBRAH_VM_ID", "unknown"))
    ehr_ready = synthetic_ehr_ready(config_dir)
    return {
        "status": "ok" if ehr_ready else "starting",
        "vm_id": vm_id,
        "stage": "ready" if ehr_ready else "synthetic_ehr_boot",
        "org_id": env.get("HEBRAH_ORG_ID"),
        "connection_id": env.get("HEBRAH_CONNECTION_ID"),
        "environment": env.get("HEBRAH_ENVIRONMENT"),
        "synthetic_ehr_ready": ehr_ready,
        "ehr_vendor": env.get("HEBRAH_EHR_VENDOR"),
        "ehr_model_version": env.get("HEBRAH_EHR_MODEL_VERSION"),
    }


class Handler(BaseHTTPRequestHandler):
    payload: dict = {}

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if self.path not in ("/health", "/health/"):
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(self.payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class HealthHTTPServer(HTTPServer):
    allow_reuse_address = True


def refresh_payload_loop(config_dir: Path, state_dir: Path) -> None:
    while True:
        payload = build_payload(config_dir)
        Handler.payload = payload
        if not persist_health(config_dir, state_dir, payload):
            print(
                "hebrah-sidecar-health: health.json not written to config or state dir",
                file=sys.stderr,
            )
        time.sleep(5)


def main() -> None:
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    state_dir = Path(os.environ.get("HEBRAH_STATE_DIR", "/var/lib/hebrah-sidecar"))
    port = int(os.environ.get("HEBRAH_HEALTH_PORT", "8080"))

    # Prefer /etc/hebrah.env on Firecracker (no 9p) when present.
    etc_env = Path("/etc/hebrah.env")
    if etc_env.is_file() and not (config_dir / "hebrah.env").is_file():
        try:
            config_dir.mkdir(parents=True, exist_ok=True)
            (config_dir / "hebrah.env").write_text(etc_env.read_text())
        except OSError:
            pass

    Handler.payload = {
        "status": "starting",
        "vm_id": os.environ.get("HEBRAH_VM_ID", "unknown"),
        "stage": "sidecar_boot",
    }
    try:
        server = HealthHTTPServer(("0.0.0.0", port), Handler)
    except OSError as exc:
        print(f"hebrah-sidecar-health: bind failed: {exc}", file=sys.stderr, flush=True)
        raise
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"hebrah-sidecar-health: listening on 0.0.0.0:{port}", flush=True)

    # Don't block forever on 9p when Firecracker only has a tmpfiles dir.
    if not wait_for_config_mount(config_dir, timeout_sec=5.0):
        print(
            f"hebrah-sidecar-health: {config_dir} not ready — continuing with HTTP only",
            file=sys.stderr,
            flush=True,
        )

    Handler.payload = build_payload(config_dir)
    for _attempt in range(12):
        if persist_health(config_dir, state_dir, Handler.payload):
            break
        time.sleep(0.5)

    refresh_payload_loop(config_dir, state_dir)


if __name__ == "__main__":
    main()
