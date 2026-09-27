"""Loopback-only deterministic HTTP faults; no app/backend replacement logic."""
import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log URLs or credentials.

    def do_GET(self):
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            self.close_connection = True
            return
        status = 503 if self.path == "/unavailable" else 200
        if self.path == "/malformed":
            body = b"{broken-json"
        elif self.path == "/wrong-shape":
            body = b'{"ok":"wrong-type"}'
        elif status == 503:
            body = json.dumps({"error": "temporary fixture failure"}).encode()
        else:
            body = json.dumps({"ok": True, "today": "2026-01-01", "now": "2026-01-01 12:00"}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
