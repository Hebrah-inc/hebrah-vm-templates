#!/usr/bin/env python3
"""Clinic simulator HL7 source — HTTP send templates to sidecar over TCP."""

from __future__ import annotations

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TEMPLATES = {
    "adt_a01_admit": (
        "MSH|^~\\&|CLINIC|FACILITY|HEBRAH|SANDBOX|20260613080000||ADT^A01|MSG00001|P|2.5\r"
        "PID|1||{{patient_id}}^^^HEBRAH||Demo^Patient||19800101|M\r"
        "PV1|1|I|WARD^101^01"
    ),
    "ref_i12_referral": (
        "MSH|^~\\&|CLINIC|FACILITY|HEBRAH|SANDBOX|20260613080000||REF^I12|MSG00002|P|2.5\r"
        "PID|1||{{patient_id}}^^^HEBRAH||Demo^Patient||19800101|M\r"
        "RF1|1|R|CARDIOLOGY^Specialist consult"
    ),
    "dft_p03_claim": (
        "MSH|^~\\&|CLINIC|FACILITY|HEBRAH|SANDBOX|20260613080000||DFT^P03|MSG00004|P|2.5\r"
        "PID|1||{{patient_id}}^^^HEBRAH||Demo^Patient||19800101|M\r"
        "FT1|1||20260613|20260613|CG|CLAIM^Professional|1"
    ),
}

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


def send_mllp(host: str, port: int, message: str) -> bytes:
    payload = _MLLP_START + message.encode() + _MLLP_END
    with socket.create_connection((host, port), timeout=10) as conn:
        conn.sendall(payload)
        response = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            response += chunk
            if _MLLP_END in response:
                break
    if response.startswith(_MLLP_START):
        response = response[1:]
    if response.endswith(_MLLP_END):
        response = response[: -len(_MLLP_END)]
    return response


class Handler(BaseHTTPRequestHandler):
    env: dict[str, str] = {}

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if self.path.startswith("/Patient/"):
            body = b'{"resourceType":"Patient","id":"pat_01JM","name":[{"family":"Demo","given":["Clinic"]}]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/fhir+json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/hl7/templates", "/hl7/templates/"):
            body = json.dumps({"templates": list(TEMPLATES.keys())}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if not self.path.startswith("/hl7/send/"):
            self.send_response(404)
            self.end_headers()
            return
        template_id = self.path.removeprefix("/hl7/send/").strip("/")
        template = TEMPLATES.get(template_id)
        if not template:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(json.dumps({"error": "unknown template"}).encode())
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        body = json.loads(raw) if raw else {}
        patient_id = body.get("patient_id") or "pat_01JM"
        message = template.replace("{{patient_id}}", patient_id)

        sidecar_host = self.env.get("HEBRAH_SIDECAR_HL7_HOST", "10.8.0.2")
        sidecar_port = int(self.env.get("HEBRAH_SIDECAR_HL7_PORT", "2575"))
        try:
            ack = send_mllp(sidecar_host, sidecar_port, message).decode(errors="replace")
            payload = {
                "status": "sent",
                "template_id": template_id,
                "sidecar_host": sidecar_host,
                "sidecar_port": sidecar_port,
                "ack": ack,
            }
            encoded = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except OSError as exc:
            encoded = json.dumps({"status": "error", "error": str(exc)}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)


def main() -> None:
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    Handler.env = load_env(config_dir / "hebrah.env")
    port = int(os.environ.get("HEBRAH_CLINIC_HTTP_PORT", "8081"))
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
