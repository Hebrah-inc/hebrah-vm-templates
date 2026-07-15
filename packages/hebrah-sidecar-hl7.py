#!/usr/bin/env python3
"""Sidecar HL7 receiver — MLLP :2575 and HTTP POST /hl7/inject."""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

_SEGMENT_SEP = re.compile(r"[\r\n]+")
_MLLP_START = b"\x0b"
_MLLP_END = b"\x1c\x0d"


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


def parse_hl7(message: str) -> dict:
    segments = [segment.strip() for segment in _SEGMENT_SEP.split(message.strip()) if segment.strip()]
    parsed: dict = {"segments": segments, "segment_types": [segment.split("|", 1)[0] for segment in segments]}
    msh = next((segment for segment in segments if segment.startswith("MSH|")), None)
    if msh:
        fields = msh.split("|")
        parsed["message_type"] = fields[8] if len(fields) > 8 else None
        parsed["control_id"] = fields[9] if len(fields) > 9 else None
    pid = next((segment for segment in segments if segment.startswith("PID|")), None)
    if pid:
        fields = pid.split("|")
        parsed["patient_identifier"] = fields[3] if len(fields) > 3 else None
    return parsed


def build_ack(parsed: dict, ack_code: str = "AA") -> str:
    control_id = parsed.get("control_id") or "UNKNOWN"
    return (
        f"MSH|^~\\&|HEBRAH|SIDECAR|CLINIC|FACILITY|20260613080000||ACK|{control_id}|P|2.5\r"
        f"MSA|{ack_code}|{control_id}|Message accepted"
    )


def map_event(message_type: str | None) -> str:
    mapping = {
        "ADT^A01": "patient.admitted",
        "ADT^A03": "patient.discharged",
        "ADT^A04": "patient.created",
        "ADT^A08": "patient.updated",
        "REF^I12": "referral.received",
        "REF^I13": "referral.completed",
        "DFT^P03": "claim.submitted",
        "ZEL^Z01": "eligibility.checked",
        "ZEL^Z02": "eligibility.inactive",
        "SIU^S12": "appointment.scheduled",
    }
    if not message_type:
        return "patient.admitted"
    return mapping.get(message_type.upper(), "patient.admitted")


def extract_patient_id(parsed: dict, fallback: str) -> str:
    identifier = parsed.get("patient_identifier") or ""
    if "^^^" in identifier:
        return identifier.split("^^^", 1)[0] or fallback
    if identifier:
        return identifier.split("^", 1)[0] or fallback
    return fallback


def post_internal_event(env: dict[str, str], payload: dict) -> tuple[bool, str]:
    api_url = env.get("HEBRAH_API_URL", "http://127.0.0.1:8000").rstrip("/")
    secret = env.get("HEBRAH_INTERNAL_SECRET", "")
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        f"{api_url}/v1/internal/sidecar/events",
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Hebrah-Internal-Secret": secret,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status < 300, response.read().decode()
    except urllib.error.HTTPError as exc:
        return False, exc.read().decode()
    except urllib.error.URLError as exc:
        return False, str(exc.reason)


def write_ack(config_dir: Path, payload: dict) -> None:
    text = json.dumps(payload, indent=2) + "\n"
    path = config_dir / "hl7_ack.json"
    try:
        proc = subprocess.run(
            ["/bin/sh", "-c", "cat > \"$1\"", "sh", str(path)],
            input=text,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            return
        path.write_text(text)
    except OSError:
        path.write_text(text)


def handle_hl7_message(message: str, env: dict[str, str], config_dir: Path) -> dict:
    parsed = parse_hl7(message)
    ack = build_ack(parsed)
    patient_id = extract_patient_id(parsed, "pat_01JM")
    event = map_event(parsed.get("message_type"))
    hl7_meta = {
        "message_type": parsed.get("message_type"),
        "control_id": parsed.get("control_id"),
        "segments_parsed": parsed.get("segment_types", []),
    }

    payload = {
        "vm_id": env.get("HEBRAH_VM_ID", "unknown"),
        "org_id": env.get("HEBRAH_ORG_ID", ""),
        "connection_id": env.get("HEBRAH_CONNECTION_ID", ""),
        "environment": env.get("HEBRAH_ENVIRONMENT", "sandbox"),
        "event": event,
        "patient_id": patient_id,
        "hl7": hl7_meta,
    }
    clinical_ok, clinical_msg = post_internal_event(env, payload)

    ack_payload = {
        **payload,
        "event": "tunnel.ack",
        "hl7": {**hl7_meta, "ack_code": "AA"},
    }
    ack_ok, ack_msg = post_internal_event(env, ack_payload)

    result = {
        "ack": "AA",
        "event": event,
        "clinical_delivery": clinical_ok,
        "clinical_message": clinical_msg,
        "ack_delivery": ack_ok,
        "ack_message": ack_msg,
        "ack_message_hl7": ack,
    }
    config_dir.mkdir(parents=True, exist_ok=True)
    write_ack(config_dir, result)
    return result


class InjectHandler(BaseHTTPRequestHandler):
    env: dict[str, str] = {}
    config_dir: Path = Path("/hebrah-config")

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_POST(self) -> None:
        if self.path not in ("/hl7/inject", "/hl7/inject/"):
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"message": raw}
        message = payload.get("message") or raw
        if not message:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"message required"}')
            return
        result = handle_hl7_message(message, self.env, self.config_dir)
        body = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


_EMPTY_INJECT = '{"message":""}\n'


def _refresh_9p_dir(config_dir: Path) -> None:
    """Force 9p dentry refresh so host overwrites of pre-created files are visible."""
    try:
        list(config_dir.iterdir())
    except OSError:
        pass


def _clear_inject_file(inject_path: Path) -> None:
    """Reset inject slot; keep file so QEMU 9p does not need a new host dentry."""
    try:
        inject_path.write_text(_EMPTY_INJECT)
    except OSError:
        inject_path.unlink(missing_ok=True)


def _read_inject_message(inject_path: Path) -> str | None:
    _refresh_9p_dir(inject_path.parent)
    if not inject_path.is_file():
        return None
    try:
        raw = inject_path.read_bytes()
    except OSError:
        return None
    if not raw.strip():
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    message = payload.get("message") or ""
    return message or None


def process_inject_file(config_dir: Path) -> bool:
    """Process hl7_inject.json if present; return True when handled."""
    inject_path = config_dir / "hl7_inject.json"
    message = _read_inject_message(inject_path)
    if not message:
        return False
    env = load_env(config_dir / "hebrah.env")
    handle_hl7_message(message, env, config_dir)
    _clear_inject_file(inject_path)
    return True


def poll_9p_inject(config_dir: Path) -> None:
    """Process hl7_inject.json dropped on the 9p share (nested QEMU hostfwd fallback)."""
    inject_path = config_dir / "hl7_inject.json"
    while True:
        message = _read_inject_message(inject_path)
        if message:
            env = load_env(config_dir / "hebrah.env")
            try:
                handle_hl7_message(message, env, config_dir)
                _clear_inject_file(inject_path)
            except (OSError, ValueError, urllib.error.URLError):
                pass
        time.sleep(0.25)


def serve_mllp(env: dict[str, str], config_dir: Path, port: int) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", port))
    server.listen(5)
    while True:
        conn, _addr = server.accept()
        with conn:
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if _MLLP_END in data:
                    break
            if data.startswith(_MLLP_START):
                data = data[1:]
            if data.endswith(_MLLP_END):
                data = data[: -len(_MLLP_END)]
            message = data.decode(errors="replace")
            result = handle_hl7_message(message, env, config_dir)
            ack_bytes = _MLLP_START + result["ack_message_hl7"].encode() + _MLLP_END
            conn.sendall(ack_bytes)


def main() -> None:
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    env = load_env(config_dir / "hebrah.env")
    http_port = int(os.environ.get("HEBRAH_HL7_HTTP_PORT", "8083"))
    mllp_port = int(os.environ.get("HEBRAH_HL7_MLLP_PORT", "2575"))

    InjectHandler.env = env
    InjectHandler.config_dir = config_dir
    http_server = HTTPServer(("0.0.0.0", http_port), InjectHandler)
    threading.Thread(target=http_server.serve_forever, daemon=True).start()
    threading.Thread(target=poll_9p_inject, args=(config_dir,), daemon=True).start()
    serve_mllp(env, config_dir, mllp_port)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--inject-file":
        config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
        try:
            process_inject_file(config_dir)
        except Exception as exc:
            print(f"hebrah-sidecar-hl7 inject-file: {exc}", file=sys.stderr)
        sys.exit(0)
    else:
        main()
