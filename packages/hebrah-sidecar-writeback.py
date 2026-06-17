#!/usr/bin/env python3
"""Sidecar synthetic EHR write-back stubs on :8082."""

from __future__ import annotations

import json
import os
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


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


def post_internal_event(env: dict[str, str], payload: dict) -> tuple[bool, str]:
    api_url = env.get("HEBRAH_API_URL", "http://127.0.0.1:8000").rstrip("/")
    secret = env.get("HEBRAH_INTERNAL_SECRET", "")
    body = json.dumps(payload).encode()
    request = Request(
        f"{api_url}/v1/internal/sidecar/events",
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Hebrah-Internal-Secret": secret,
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:
            return response.status < 300, response.read().decode()
    except HTTPError as exc:
        return False, exc.read().decode()
    except URLError as exc:
        return False, str(exc.reason)


class Handler(BaseHTTPRequestHandler):
    env: dict[str, str] = {}

    def log_message(self, fmt: str, *args) -> None:
        return

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        return json.loads(raw) if raw else {}

    def _write_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        fail = query.get("fail", ["false"])[0].lower() == "true"
        routes = {
            "/v1/writeback/chart-note": "chart-note",
            "/v1/writeback/order": "order",
            "/v1/writeback/task-response": "task-response",
        }
        action = routes.get(parsed.path)
        if not action:
            self.send_response(404)
            self.end_headers()
            return

        try:
            body = self._read_json()
        except json.JSONDecodeError:
            self._write_json(400, {"error": "invalid json"})
            return

        patient_id = body.get("patient_id") or "pat_01JM"
        action_id = f"wb_{uuid.uuid4().hex[:12]}"
        if fail:
            event = "sidecar.writeback.failed"
            status = "failed"
            http_status = 409
        else:
            event = "sidecar.writeback.succeeded"
            status = "accepted"
            http_status = 200

        payload = {
            "vm_id": self.env.get("HEBRAH_VM_ID", "unknown"),
            "org_id": self.env.get("HEBRAH_ORG_ID", ""),
            "connection_id": self.env.get("HEBRAH_CONNECTION_ID", ""),
            "environment": self.env.get("HEBRAH_ENVIRONMENT", "sandbox"),
            "event": event,
            "patient_id": patient_id,
            "action": action,
            "metadata": {"action_id": action_id, **body},
        }
        delivered, message = post_internal_event(self.env, payload)
        self._write_json(
            http_status,
            {
                "status": status,
                "action": action,
                "action_id": action_id,
                "delivered": delivered,
                "delivery_message": message,
            },
        )


def main() -> None:
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    Handler.env = load_env(config_dir / "hebrah.env")
    port = int(os.environ.get("HEBRAH_WRITEBACK_PORT", "8082"))
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
