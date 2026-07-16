#!/usr/bin/env python3
"""Per-VM synthetic EHR — vendor-aware FHIR store in SQLite."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

_ENV_FILE_MAX_BYTES = 1 << 20
_ENV_KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def _valid_env_value(value: str) -> bool:
    return value != "" and not re.search(r"[\x00-\x1f=]", value)


def load_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    try:
        st = os.lstat(path)
    except OSError:
        return data
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return data
    if st.st_size > _ENV_FILE_MAX_BYTES:
        return data
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return data
    try:
        raw = os.read(fd, _ENV_FILE_MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > _ENV_FILE_MAX_BYTES:
        return data
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return data
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key_s = key.strip()
        val_s = value.strip()
        if key_s in data or not _ENV_KEY_RE.fullmatch(key_s) or not _valid_env_value(val_s):
            continue
        data[key_s] = val_s
    return data


def load_model_pack(config_dir: Path) -> dict:
    model_dir = config_dir / "ehr-model"
    for candidate in (model_dir / "pack.json", model_dir / "v1.json"):
        if candidate.is_file():
            return json.loads(candidate.read_text())
    vendor = os.environ.get("HEBRAH_EHR_VENDOR", "Epic")
    slug = vendor.lower()
    return {
        "vendor": vendor,
        "version": "1.0.0",
        "fhir": {"base_path": "/fhir/R4", "resource_types": ["Patient"]},
        "seed": {"patients": 5},
        "_fallback": slug,
    }


def load_seed_bundle(config_dir: Path) -> dict | None:
    model_dir = config_dir / "ehr-model"
    path = model_dir / "seed-bundle.json"
    if path.is_file():
        return json.loads(path.read_text())
    return None


class EhrStore:
    def __init__(self, db_path: Path, connection_id: str, pack: dict, config_dir: Path) -> None:
        self.db_path = db_path
        self.connection_id = connection_id
        self.pack = pack
        self.config_dir = config_dir
        self._reseed_lock = threading.Lock()
        self._last_reseed_trigger_mtime: float | None = None
        self._init_db()
        self.seed()

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self._conn() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS resources (
                    resource_type TEXT NOT NULL,
                    resource_id TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    PRIMARY KEY (resource_type, resource_id)
                )
                """
            )

    def _patient_id(self, index: int) -> str:
        seed = self.connection_id.replace("-", "_")[:32]
        return f"pat_{seed}_{index:02d}"

    def _load_bundle_into_db(self, bundle: dict | None) -> None:
        if bundle and bundle.get("resources"):
            with self._conn() as conn:
                for entry in bundle["resources"]:
                    resource = entry.get("resource") or entry
                    resource_type = resource.get("resourceType") or entry.get("resourceType")
                    resource_id = resource.get("id") or entry.get("id")
                    if not resource_type or not resource_id:
                        continue
                    conn.execute(
                        "INSERT OR REPLACE INTO resources (resource_type, resource_id, payload) VALUES (?, ?, ?)",
                        (resource_type, resource_id, json.dumps(resource)),
                    )
            return

        count = int(self.pack.get("seed", {}).get("patients", 5))
        vendor = self.pack.get("vendor", "Epic")
        with self._conn() as conn:
            for i in range(1, count + 1):
                pid = self._patient_id(i)
                digest = hashlib.blake2b(f"{self.connection_id}:{pid}".encode(), digest_size=4).hexdigest()
                family = ["Chen", "Patel", "Nguyen", "Garcia", "Kim"][(i - 1) % 5]
                given = ["Alex", "Jordan", "Sam", "Riley", "Casey"][(i - 1) % 5]
                payload = {
                    "resourceType": "Patient",
                    "id": pid,
                    "meta": {"profile": [f"{vendor}/Patient"]},
                    "identifier": [{"system": f"urn:hebrah:{vendor.lower()}", "value": f"{digest[:8]}"}],
                    "name": [{"family": family, "given": [given]}],
                    "gender": "unknown",
                    "birthDate": f"198{i}-0{i}-15",
                }
                conn.execute(
                    "INSERT OR REPLACE INTO resources (resource_type, resource_id, payload) VALUES (?, ?, ?)",
                    ("Patient", pid, json.dumps(payload)),
                )

    def seed(self) -> None:
        bundle = load_seed_bundle(self.config_dir)
        self._load_bundle_into_db(bundle)

    def reseed(self) -> dict:
        with self._reseed_lock:
            self.pack = load_model_pack(self.config_dir)
            with self._conn() as conn:
                conn.execute("DELETE FROM resources")
            self.seed()
            return self.health_payload()

    def sqlite_resource_counts(self) -> dict[str, int]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT resource_type, COUNT(*) AS cnt FROM resources GROUP BY resource_type"
            ).fetchall()
        return {row["resource_type"]: row["cnt"] for row in rows}

    def health_payload(self) -> dict:
        bundle = load_seed_bundle(self.config_dir)
        return {
            "status": "ok",
            "bundle_version": bundle.get("version") if bundle else None,
            "resource_counts": self.sqlite_resource_counts(),
            "connection_id": self.connection_id,
            "vendor": self.pack.get("vendor", "Epic"),
        }

    def get_resource(self, resource_type: str, resource_id: str) -> dict | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT payload FROM resources WHERE resource_type = ? AND resource_id = ?",
                (resource_type, resource_id),
            ).fetchone()
        return json.loads(row["payload"]) if row else None

    def list_ids(self, resource_type: str) -> list[str]:
        with self._conn() as conn:
            rows = conn.execute(
                "SELECT resource_id FROM resources WHERE resource_type = ? ORDER BY resource_id",
                (resource_type,),
            ).fetchall()
        return [row["resource_id"] for row in rows]

    def metadata(self) -> dict:
        return {
            "resourceType": "CapabilityStatement",
            "status": "active",
            "fhirVersion": "4.0.1",
            "kind": "instance",
            "software": {"name": f"Hebrah Synthetic EHR ({self.pack.get('vendor', 'Epic')})"},
            "rest": [{
                "mode": "server",
                "resource": [{"type": rt, "interaction": [{"code": "read"}]} for rt in self.pack.get("fhir", {}).get("resource_types", ["Patient"])],
            }],
        }

    def watch_reseed_trigger(self) -> None:
        trigger = self.config_dir / "ehr-model" / "reseed.trigger"
        while True:
            try:
                if trigger.is_file():
                    mtime = trigger.stat().st_mtime
                    if self._last_reseed_trigger_mtime is None or mtime > self._last_reseed_trigger_mtime:
                        self._last_reseed_trigger_mtime = mtime
                        self.reseed()
                        trigger.unlink(missing_ok=True)
            except OSError:
                pass
            time.sleep(2)


STORE: EhrStore | None = None
PACK: dict = {}
BASE_PATH = "/fhir/R4"
INTERNAL_SECRET = ""
HANDOFF_ACTIVE = False
_HANDOFF_LOCK = threading.Lock()
FHIR_PORT = 8090
ADMIN_PORT = 8091


def _handoff_dev_allows_open_admin() -> bool:
    return os.getenv("HEBRAH_ALLOW_OPEN_ADMIN", "").lower() in ("1", "true", "yes")


def set_handoff_active(active: bool) -> None:
    global HANDOFF_ACTIVE
    with _HANDOFF_LOCK:
        HANDOFF_ACTIVE = active


def reload_env_from_mmds() -> dict:
    """Re-read hebrah.env from MMDS or shared config (Phase 2/3 hot claim)."""
    global STORE, PACK, BASE_PATH, INTERNAL_SECRET
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    etc_env = Path("/etc/hebrah.env")
    fetched = False
    source = "mmds"
    text = ""
    for attempt in range(8):
        try:
            with urllib.request.urlopen(
                "http://169.254.169.254/hebrah.env", timeout=1
            ) as resp:
                text = resp.read().decode()
            fetched = True
            source = "mmds"
            break
        except (urllib.error.URLError, TimeoutError, OSError):
            local = config_dir / "hebrah.env"
            if local.is_file():
                text = local.read_text(encoding="utf-8")
                fetched = True
                source = "local"
                break
            time.sleep(0.1)
    if fetched and text:
        etc_env.write_text(text)
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "hebrah.env").write_text(text)
        env = load_env(config_dir / "hebrah.env")
        INTERNAL_SECRET = env.get(
            "HEBRAH_INTERNAL_SECRET",
            os.environ.get("HEBRAH_INTERNAL_SECRET", ""),
        )
        PACK = load_model_pack(config_dir)
        BASE_PATH = PACK.get("fhir", {}).get("base_path", "/fhir/R4")
        if STORE is not None:
            STORE.connection_id = env.get("HEBRAH_CONNECTION_ID", STORE.connection_id)
            STORE.pack = PACK
            STORE.config_dir = config_dir
    restarted: list[str] = []
    if fetched:
        # Never restart hebrah-synthetic-ehr here — this handler runs inside that unit.
        units = (
            "hebrah-sidecar-wg.service",
            "hebrah-sidecar-health.service",
        )
        procs = [
            subprocess.Popen(
                ["systemctl", "restart", unit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for unit in units
        ]
        for proc, unit in zip(procs, units, strict=True):
            if proc.wait(timeout=10) == 0:
                restarted.append(unit)
    return {
        "status": "ok" if fetched else "mmds_unavailable",
        "source": source,
        "restarted": restarted,
    }

class FhirHandler(BaseHTTPRequestHandler):
    """Public FHIR + health on :8090 (DNAT-exposed data plane)."""

    def log_message(self, fmt: str, *args) -> None:
        return

    def _json(self, code: int, body: dict | list, *, content_type: str = "application/fhir+json") -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handoff_blocks_fhir(self) -> bool:
        with _HANDOFF_LOCK:
            return HANDOFF_ACTIVE

    def do_GET(self) -> None:
        global STORE, PACK, BASE_PATH
        path = urlparse(self.path).path
        if path == "/health":
            payload = STORE.health_payload() if STORE else {"status": "starting"}
            with _HANDOFF_LOCK:
                payload = {**payload, "handoff_active": HANDOFF_ACTIVE}
            self._json(200, payload, content_type="application/json")
            return
        if self._handoff_blocks_fhir():
            self._json(
                503,
                {"error": "handoff_active", "message": "FHIR unavailable during tenant handoff"},
                content_type="application/json",
            )
            return
        if path in ("/metadata", f"{BASE_PATH}/metadata"):
            self._json(200, STORE.metadata() if STORE else {"status": "starting"})
            return
        prefix = f"{BASE_PATH}/"
        if STORE and path.startswith(prefix):
            parts = path[len(prefix):].split("/")
            if len(parts) == 2:
                resource_type, resource_id = parts
                resource = STORE.get_resource(resource_type, urllib.parse.unquote(resource_id))
                if resource:
                    self._json(200, resource)
                    return
            if len(parts) == 1 and parts[0]:
                ids = STORE.list_ids(parts[0])
                bundle = {
                    "resourceType": "Bundle",
                    "type": "searchset",
                    "total": len(ids),
                    "entry": [{"resource": STORE.get_resource(parts[0], rid)} for rid in ids],
                }
                self._json(200, bundle)
                return
        self.send_response(404)
        self.end_headers()


class AdminHandler(BaseHTTPRequestHandler):
    """Tap-only admin on :8091 — not DNAT'd on host (Phase 8)."""

    def log_message(self, fmt: str, *args) -> None:
        return

    def _json(self, code: int, body: dict | list, *, content_type: str = "application/json") -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized_admin(self) -> bool:
        if not INTERNAL_SECRET:
            return _handoff_dev_allows_open_admin()
        return self.headers.get("X-Hebrah-Internal-Secret", "") == INTERNAL_SECRET

    def do_POST(self) -> None:
        global STORE
        path = urlparse(self.path).path
        if not self._authorized_admin():
            self._json(401, {"error": "unauthorized"}, content_type="application/json")
            return
        if path == "/admin/handoff-begin":
            set_handoff_active(True)
            self._json(200, {"status": "ok", "handoff_active": True}, content_type="application/json")
            return
        if path == "/admin/handoff-complete":
            set_handoff_active(False)
            self._json(200, {"status": "ok", "handoff_active": False}, content_type="application/json")
            return
        if path == "/admin/reseed":
            if not STORE:
                self._json(503, {"error": "store not ready"}, content_type="application/json")
                return
            self._json(200, STORE.reseed(), content_type="application/json")
            return
        if path == "/admin/reload-env":
            self._json(200, reload_env_from_mmds(), content_type="application/json")
            return
        self.send_response(404)
        self.end_headers()


class Handler(FhirHandler):
    """Backward-compatible alias for tests importing Handler."""


def main() -> None:
    global STORE, PACK, BASE_PATH, INTERNAL_SECRET, FHIR_PORT, ADMIN_PORT
    config_dir = Path(os.environ.get("HEBRAH_CONFIG_DIR", "/hebrah-config"))
    state_dir = Path(os.environ.get("HEBRAH_STATE_DIR", "/var/lib/hebrah-sidecar"))
    env = load_env(config_dir / "hebrah.env")
    connection_id = env.get("HEBRAH_CONNECTION_ID", "conn_unknown")
    FHIR_PORT = int(env.get("HEBRAH_SYNTHETIC_EHR_PORT", os.environ.get("HEBRAH_SYNTHETIC_EHR_PORT", "8090")))
    ADMIN_PORT = int(env.get("HEBRAH_ADMIN_PORT", os.environ.get("HEBRAH_ADMIN_PORT", "8091")))
    INTERNAL_SECRET = env.get("HEBRAH_INTERNAL_SECRET", os.environ.get("HEBRAH_INTERNAL_SECRET", ""))
    PACK = load_model_pack(config_dir)
    BASE_PATH = PACK.get("fhir", {}).get("base_path", "/fhir/R4")
    db_path = state_dir / "ehr.db"
    STORE = EhrStore(db_path, connection_id, PACK, config_dir)
    threading.Thread(target=STORE.watch_reseed_trigger, daemon=True).start()

    def serve_fhir() -> None:
        HTTPServer(("0.0.0.0", FHIR_PORT), FhirHandler).serve_forever()

    def serve_admin() -> None:
        HTTPServer(("0.0.0.0", ADMIN_PORT), AdminHandler).serve_forever()

    threading.Thread(target=serve_fhir, name="fhir-8090", daemon=True).start()
    print(
        f"hebrah-synthetic-ehr: {PACK.get('vendor')} fhir=:{FHIR_PORT} admin=:{ADMIN_PORT}{BASE_PATH}",
        file=sys.stderr,
    )
    serve_admin()


if __name__ == "__main__":
    main()
