#!/usr/bin/env python3
"""真实 CLI + API.swift 对本机合同桩，验证 JSON/授权出口；没有云 SDK、真实号码或短信投递。"""
import json
import os
import stat
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "build/cli/fitcoach"
requests = []
counter = {"send": 0, "login": 0}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        requests.append((self.path, None, self.headers.get("Cookie"), None))
        if self.path == "/api/account_hints":
            self.reply({"ok": True, "sms": {"enabled": True, "resend_seconds": 12, "code_ttl_seconds": 90, "sign_name": "测试签名"}})
        elif self.path == "/coach/api/account":
            self.reply({"ok": True, "coach_id": 7, "has_password": False, "phone_verified": True, "phone_hint": "139****0101"})
        elif self.path == "/coach/api/ping":
            if self.headers.get("Cookie") == "fc_coach=expired-cookie":
                self.reply({"error": "expired"}, 404)
            else:
                self.reply({"ok": True, "today": "2026-10-06", "now": "2026-10-06 10:00:00"})
        else:
            self.reply({"error": "unknown"}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append((self.path, body, self.headers.get("Cookie"), self.headers.get("Content-Type")))
        if self.path == "/api/phone_send":
            counter["send"] += 1
            if counter["send"] == 1:
                self.reply({"error": "发送结果未知，请用原请求查询"}, 503)
            else:
                self.reply({"ok": True, "challenge_id": "synthetic-challenge", "resend_seconds": 12, "code_ttl_seconds": 90, "sign_name": "测试签名"})
        elif self.path == "/api/phone_verify":
            assert body["code"] == "246810"
            if body["challenge_id"] in ("public-401", "authenticated-401"):
                self.reply({"error": "会话或挑战失效"}, 401)
            else:
                self.reply({"ok": True, "verification_token": "synthetic-" + body["challenge_id"]})
        elif self.path == "/api/phone_register":
            assert body["agreed"] is True
            self.reply({"ok": True, "coach_id": 7, "cookie": "registered-cookie", "email": "", "recovery_key": "synthetic-once-only-key"})
        elif self.path == "/api/phone_login":
            counter["login"] += 1
            if counter["login"] == 1:
                self.reply({"error": "请补独立恢复密钥", "code": "ownership_required"}, 403)
            else:
                assert body["recovery_key"] == "synthetic-once-only-key"
                self.reply({"ok": True, "coach_id": 7, "cookie": "login-cookie", "email": ""})
        elif self.path == "/coach/api/phone_bind":
            if body["phone"] == "13900000103":
                self.reply({"error": "手机号已被其他账号绑定", "code": "phone_in_use"}, 409)
                return
            assert body["old_verification_token"] == body["identity_grant"]
            self.reply({"ok": True, "coach_id": 7, "cookie": "bound-cookie", "phone_hint": "139****0102"})
        elif self.path == "/coach/api/password_set":
            assert body["new_password"] == "synthetic-new-password"
            self.reply({"ok": True, "cookie": "password-set-cookie"})
        elif self.path == "/api/phone_recover":
            assert body["new_password"] == "synthetic-recovered-password"
            self.reply({"ok": True, "message": "密码已重置"})
        else:
            self.reply({"error": "unknown"}, 404)

with tempfile.TemporaryDirectory(prefix="fitcoach-phone-cli-") as tmp:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    env = {**os.environ, "FITCOACH_BASE": base, "FITCOACH_CLI_HOME": tmp}
    def run(*args, stdin=None, expected=0):
        p = subprocess.run([str(CLI), "phone", *args, "--json"], input=stdin, text=True, capture_output=True, timeout=20, env=env)
        assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
        assert "246810" not in p.stdout and "synthetic-once-only-key" not in p.stdout
        return json.loads(p.stdout)
    def verify(name, authenticated=False):
        args = ["verify", "--challenge", name, "--code-stdin"] + (["--authenticated"] if authenticated else [])
        result = run(*args, stdin="246810\n")
        file = Path(result["grant_file"])
        assert stat.S_IMODE(file.stat().st_mode) == 0o600
        return file
    try:
        run("send", "--purpose", "register", "--phone", "13900000101", "--request-id", "isolated-request-id-0001", expected=5)
        assert not requests
        run("hints")
        args = ("send", "--purpose", "register", "--phone", "13900000101", "--request-id", "isolated-request-id-0001", "--confirm-send")
        run(*args, expected=1)
        run(*args)
        assert requests[-2][1]["request_id"] == requests[-1][1]["request_id"]
        assert requests[-1][2] is None and requests[-1][3] == "application/json"
        run("verify", "--challenge", "register", "--code", "246810", expected=2)
        grant = verify("register")
        response = run("register", "--grant-file", str(grant), "--display-name", "隔离教练", "--agreed")
        assert not grant.exists()
        recovery = Path(response["recovery_key_file"])
        assert stat.S_IMODE(recovery.stat().st_mode) == 0o600
        assert json.loads(recovery.read_text())["recovery_key"] == "synthetic-once-only-key"
        credentials = Path(tmp) / "credentials.json"
        assert stat.S_IMODE(credentials.stat().st_mode) == 0o600
        assert "registered-cookie" in credentials.read_text()
        run("hints")
        assert requests[-1][2] is None
        grant = verify("login")
        run("login", "--grant-file", str(grant), expected=4)
        assert grant.exists(), "risk rejection must retain consumed candidate for supplemental ownership"
        run("login", "--grant-file", str(grant), "--ownership-stdin", stdin=json.dumps({"recovery_key": "synthetic-once-only-key"}))
        assert not grant.exists() and "login-cookie" in credentials.read_text()
        old = verify("change_old", True)
        new = verify("change_new", True)
        assert requests[-1][2] == "fc_coach=login-cookie"
        run("bind", "--phone", "13900000102", "--grant-file", str(new), "--old-grant-file", str(old))
        assert not old.exists() and not new.exists()
        assert "bound-cookie" in credentials.read_text()
        identity = verify("identity", True)
        run("set-password", "--identity-grant-file", str(identity), "--password-stdin", stdin="synthetic-new-password\n")
        assert "password-set-cookie" in credentials.read_text() and not identity.exists()
        valid_credential = credentials.read_bytes()
        run("verify", "--challenge", "public-401", "--code-stdin", stdin="246810\n", expected=6)
        assert credentials.read_bytes() == valid_credential, "anonymous 401 must preserve an existing coach session"
        run("verify", "--challenge", "authenticated-401", "--code-stdin", "--authenticated", stdin="246810\n", expected=4)
        assert credentials.read_bytes() == valid_credential, "wrong OTP 401 plus healthy ping must preserve coach session"
        occupied_grant = verify("occupied", True)
        result = run("bind", "--phone", "13900000103", "--grant-file", str(occupied_grant), expected=4)
        assert result["error"] == "手机号已被其他账号绑定" and result["code"] == "rejected"
        assert occupied_grant.exists(), "non-warning 409 must keep input and show real reason"
        expired = json.loads(valid_credential)
        expired["accounts"][base]["cookie"] = "expired-cookie"
        credentials.write_text(json.dumps(expired))
        credentials.chmod(0o600)
        run("verify", "--challenge", "authenticated-401", "--code-stdin", "--authenticated", stdin="246810\n", expected=6)
        assert not credentials.exists(), "authenticated 401 must clear the invalid coach session"
        credentials.write_bytes(valid_credential)
        credentials.chmod(0o600)
        grant = verify("recover")
        run("recover", "--grant-file", str(grant), "--secrets-stdin", stdin=json.dumps({"new_password": "synthetic-recovered-password"}), expected=2)
        assert grant.exists(), "missing independent recovery proof must not consume the SMS grant"
        run("recover", "--grant-file", str(grant), "--secrets-stdin", stdin=json.dumps({"new_password": "synthetic-recovered-password", "recovery_key": "synthetic-once-only-key"}))
        assert not credentials.exists() and not grant.exists()
        assert recovery.exists(), "recovery key must remain available after logout/reset"
        print("PASS: CLI 短信合同桩（JSON、凭证隔离、未知发送同ID、风险补证、双号换绑、密码设置、找回、0600文件与成功核销）")
    finally:
        server.shutdown()
