#!/usr/bin/env python3
"""契约对账用的假后端：只回两种形状，验客户端对 `ui` 段的容错（ref/run 起它，跑完杀掉）。

  GET /coach/api/ping      → 其余字段正常，`ui` 段类型全错（后端坏到发出不合形状的覆盖项）
  GET /coach/api/schedule  → 一份合法的空课表，**不带** `ui` 键（旧后端的样子）
"""
import http.server
import json
import sys

BODIES = {
    "/coach/api/ping": {
        "ok": True, "today": "2026-10-06", "now": "2026-10-06 10:00",
        "ui": {"copy": {"schedule.empty.title": 1}, "vocab": "oops", "order": {"a": 1}, "limits": []},
    },
    "/coach/api/schedule": {
        "range": "today", "date": "2026-10-06", "title": "今天", "prev_date": "2026-10-05",
        "next_date": "2026-10-07", "today": "2026-10-06", "now": "2026-10-06 10:00",
        "days": [], "warnings": [],
    },
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = BODIES.get(self.path.split("?")[0])
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
