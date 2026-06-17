#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if not self.path.startswith("/Patient/"):
            self.send_response(404)
            self.end_headers()
            return
        body = b'{"resourceType":"Patient","id":"pat_01JM","name":[{"family":"Demo","given":["Clinic"]}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/fhir+json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
