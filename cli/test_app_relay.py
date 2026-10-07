#!/usr/bin/env python3
"""fitcoach config / update / app：转调 Mac 版 App 可执行文件的隔离测试。由 cli/test_app_relay.sh 调用。

走真入口（build/cli/fitcoach）转到本次编出的 App 可执行文件（FITCOACH_APP 直接指向测试 .app 壳里的可执行文件）。
全部隔离：
  偏好    测试 .app 壳的 bundle id 是专用的测试域 cyou.tianli.fitcoachapp.relaytest（具名域，跑完删掉）。
          不能用正式 bundle id：没进沙盒的进程会写 ~/Library/Preferences/cyou.tianli.fitcoachapp.plist，
          CFFIXED_USER_HOME 也拦不住（2026-10-07 实测，偏好由守护进程按真实用户落盘）。
  配置同步目录、更新目录    临时目录（APP_LIFECYCLE_SUPPORT_DIR / APP_LIFECYCLE_CLOUD_DIR）。
  通知与钥匙串    隔离运行不发跨进程通知、不读写钥匙串。
本人真实的偏好、iCloud、钥匙串、已装的 App 一律不碰；末尾核对正式偏好域前后没有变化。
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = os.environ.get("FITCOACH_TEST_CLI") or str(ROOT / "build" / "cli" / "fitcoach")
APP = Path(sys.argv[1]).resolve()
REAL_BUNDLE = "cyou.tianli.fitcoachapp"
REAL_PREFS = Path.home() / "Library/Preferences" / f"{REAL_BUNDLE}.plist"
with open(APP / "Contents/Info.plist", "rb") as handle:
    INFO = plistlib.load(handle)
BUNDLE = INFO["CFBundleIdentifier"]
TEST_PREFS = Path.home() / "Library/Preferences" / f"{BUNDLE}.plist"
if BUNDLE == REAL_BUNDLE or not BUNDLE.endswith(".relaytest"):
    sys.exit(f"FAIL: 测试 .app 壳的 bundle id 必须是专用测试域（现为 {BUNDLE}）；用正式 bundle id 会写到本人真实偏好域")
EXECUTABLE = APP / "Contents/MacOS" / INFO["CFBundleExecutable"]


def drop_test_domain() -> None:
    subprocess.run(["/usr/bin/defaults", "delete", BUNDLE], capture_output=True, timeout=20)
    # 具名域清空后偏好守护进程会补写一个 42 字节的空壳：一并删掉。
    subprocess.run(["/usr/bin/killall", "-u", os.environ.get("USER", ""), "cfprefsd"], capture_output=True, timeout=20)
    if TEST_PREFS.exists() and TEST_PREFS.stat().st_size < 100:
        TEST_PREFS.unlink()

passed = failed = 0


def check(ok: bool, label: str, detail: str = "") -> bool:
    global passed, failed
    if ok:
        passed += 1
        print(f"  ✅ {label}")
    else:
        failed += 1
        print(f"  ❌ {label}" + (f"\n     {detail.strip()[:900]}" if detail else ""))
    return ok


def stamp(path: Path):
    return (path.stat().st_mtime_ns, path.stat().st_size) if path.exists() else None


with tempfile.TemporaryDirectory(prefix="fitcoach-relay-") as scratch:
    tmp = Path(scratch)
    support, cloud = tmp / "support", tmp / "cloud"
    for directory in (support, cloud):
        directory.mkdir(parents=True)
    env = {**os.environ, "FITCOACH_APP": str(EXECUTABLE), "APP_LIFECYCLE_SUPPORT_DIR": str(support),
           "APP_LIFECYCLE_CLOUD_DIR": str(cloud), "FITCOACH_CLI_HOME": str(tmp / "cli-home")}
    for name in ("APP_LIFECYCLE_FOLLOW_CHANNEL", "CFFIXED_USER_HOME"):
        env.pop(name, None)
    real_before = stamp(REAL_PREFS)
    subprocess.run(["/usr/bin/defaults", "delete", BUNDLE], capture_output=True, timeout=20)

    def run(*args: str, expect: int = 0, label: str | None = None, extra: dict | None = None, want_json: bool = True):
        p = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, env={**env, **(extra or {})})
        data = None
        if want_json and p.stdout.strip():
            try:
                data = json.loads(p.stdout)
            except json.JSONDecodeError:
                data = None
        check(p.returncode == expect, label or f"{' '.join(args)} → 退出 {expect}", f"退出 {p.returncode}\nstdout: {p.stdout}\nstderr: {p.stderr}")
        return p, data or {}

    def code(data: dict) -> str:
        return (data.get("error") or {}).get("code", "")

    print("帮助")
    p, _ = run("--help", want_json=False)
    for needle in ("config         ", "update         ", "app            ", "config / update / app 只用三个", "app saved-login status"):
        check(needle in p.stdout, f"顶层帮助有「{needle.strip()}」")
    check("暂无命令入口" not in p.stdout and "命令读不到也改不了" not in p.stdout, "顶层帮助不再说配置与更新、服务器地址没有命令")
    for verb, needles in {"config": ["config status", "config export -o", "config import", "config sync on|off", "--json", "退出码", "fitcoach.baseURL", "--base"],
                          "update": ["update check", "update install --yes", "--dry-run", "--json", "退出码", "manual_install"],
                          "app": ["app saved-login status", "app saved-login clear --yes", "app logout --yes", "--json", "退出码", "不带密码", "fitcoach login / logout"]}.items():
        p, _ = run(verb, "--help", want_json=False, label=f"{verb} --help → 退出 0")
        missing = [n for n in needles if n not in p.stdout]
        check(not missing, f"{verb} --help 写全了子命令、--json 与退出码", f"缺：{missing}")

    print("找不到或太旧的 App：不启动任何东西")
    _, d = run("config", "status", "--json", expect=1, extra={"FITCOACH_APP": str(tmp / "none.app")})
    check(d.get("ok") is False and code(d) == "app_missing", "没有 App → app_missing", str(d))
    old = tmp / "old.app/Contents/MacOS"
    old.mkdir(parents=True)
    (old.parent / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": REAL_BUNDLE, "CFBundleExecutable": "FitCoach",
                                                           "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "6"}))
    (old / "FitCoach").write_text(f"#!/bin/sh\ntouch '{tmp}/old-was-launched'\n")
    (old / "FitCoach").chmod(0o755)
    _, d = run("app", "logout", "--yes", "--json", expect=1, extra={"FITCOACH_APP": str(tmp / "old.app")})
    check(code(d) == "app_outdated" and not (tmp / "old-was-launched").exists(), "旧版 App（没有命令入口）→ app_outdated，且没有被启动", str(d))
    _, d = run("config", "status", "--base", "https://example.com", "--json", expect=2)
    check(code(d) == "usage" and "--base" in (d.get("error") or {}).get("message", ""), "config 不接受 --base，说明两者的区别", str(d))

    print("config（共用命令层，经 App 可执行文件）")
    _, d = run("config", "status", "--json")
    check(d.get("ok") is True and d.get("command") == "config status" and d.get("has_settings") is True and d.get("sync_enabled") is False
          and isinstance(d.get("sync_status"), dict) and {"text", "from", "live"} <= set(d["sync_status"]), "config status 的字段齐（含 sync_status）", str(d))
    _, d = run("config", "--json", label="config（省略 status）→ 退出 0")
    check(d.get("command") == "config status", "省略子命令就是 status", str(d))
    target = tmp / "exported.json"
    _, d = run("config", "export", "-o", str(target), "--json")
    exported = json.loads(target.read_text()) if target.exists() else {}
    check(d.get("ok") is True and d.get("path") == str(target) and d.get("bytes") == target.stat().st_size and isinstance(d.get("keys"), list)
          and isinstance(exported.get("values"), dict), "config export 写了指定文件，path / bytes / keys 对得上", f"{d}\n{exported}")
    _, d = run("config", "export", "-o", str(target), "--json", expect=2)
    check(code(d) == "file_exists" and json.loads(target.read_text()) == exported, "目标已存在缺 --force → file_exists，文件没动", str(d))
    run("config", "export", "-o", str(target), "--force", "--json", label="config export --force → 退出 0")
    p, _ = run("config", "export", "-o", "-", want_json=False, label="config export -o - → 退出 0")
    check(json.loads(p.stdout) == json.loads(target.read_text()), "-o - 输出的就是文件里那份")
    _, d = run("config", "export", "--json", expect=2, label="config export 缺 -o → 退出 2")
    check(code(d) == "usage", "缺 -o → usage", str(d))

    moved = dict(exported)
    moved["values"] = {**exported.get("values", {}), "defaults.fitcoach.baseURL": "https://fit.example.org"}
    incoming = tmp / "incoming.json"
    incoming.write_text(json.dumps(moved))
    _, d = run("config", "import", str(tmp / "nope.json"), "--yes", "--json", expect=1)
    check(code(d) == "not_found", "导入不存在的文件 → not_found", str(d))
    _, d = run("config", "import", str(incoming), "--json", expect=2)
    check(code(d) == "confirmation_required", "导入缺 --yes → confirmation_required", str(d))
    bad = tmp / "bad.json"
    bad.write_text("not a configuration")
    _, d = run("config", "import", str(bad), "--yes", "--json", expect=1)
    check(code(d) == "import_rejected", "导入不是配置的文件 → import_rejected", str(d))
    p, d = run("config", "import", str(incoming), "--yes", "--json")
    check(d.get("imported") is True and d.get("path") == str(incoming) and "fitcoach-import-" not in p.stdout, "导入成功，path 是给的那个文件", p.stdout)
    p, _ = run("config", "export", "-o", "-", want_json=False, label="导入后另起进程读回 → 退出 0")
    back = json.loads(p.stdout) if p.stdout.strip() else {}
    check(back.get("values", {}).get("defaults.fitcoach.baseURL") == "https://fit.example.org", "另起进程读到的服务器地址是导入的值", p.stdout)
    _, d = run("config", "status", "--json")
    check("defaults.fitcoach.baseURL" in d.get("keys", []), "config status 的 keys 有 defaults.fitcoach.baseURL", str(d))
    insecure = tmp / "insecure.json"
    insecure.write_text(json.dumps({**moved, "values": {"defaults.fitcoach.baseURL": "http://plain.example.org"}}))
    run("config", "import", str(insecure), "--yes", "--json", label="导入非 https 的服务器地址 → 退出 0")
    p, _ = run("config", "export", "-o", "-", want_json=False, label="读回 → 退出 0")
    check(json.loads(p.stdout).get("values", {}).get("defaults.fitcoach.baseURL") == "https://fit.tianli.cyou", "非 https 的地址不被采用，回到默认服务器", p.stdout)
    run("config", "import", str(incoming), "--yes", "--json", label="再导入一次合法地址 → 退出 0")

    _, d = run("config", "sync", "on", "--json", expect=2)
    check(code(d) == "confirmation_required", "sync 缺 --yes → confirmation_required", str(d))
    _, d = run("config", "sync", "on", "--dry-run", "--json")
    check(d.get("would_change") is True and d.get("sync_enabled") is False, "sync on --dry-run 只说会变，不变", str(d))
    _, d = run("config", "sync", "on", "--yes", "--json")
    check(d.get("sync_enabled") is True and d.get("changed") is True, "sync on --yes 打开了开关", str(d))
    _, d = run("config", "status", "--json")
    check(d.get("sync_enabled") is True, "另起进程读回：开关是开", str(d))
    _, d = run("config", "sync", "off", "--yes", "--json")
    _, d = run("config", "status", "--json")
    check(d.get("sync_enabled") is False, "sync off 后另起进程读回：开关是关", str(d))
    p, _ = run("config", "export", "-o", "-", want_json=False, label="拨过开关后读回配置 → 退出 0")
    check(json.loads(p.stdout).get("values", {}).get("defaults.fitcoach.baseURL") == "https://fit.example.org", "拨开关没有动服务器地址", p.stdout)
    _, d = run("config", "status", "--no-such", "--json", expect=2)
    check(code(d) == "usage", "未知参数 → usage", str(d))

    print("update（面板同一条读取与校验）")
    _, d = run("update", "check", "--json", expect=1)
    check(code(d) == "check_incomplete" and d.get("current", {}).get("version") == "1.0.1", "没有发行记录 → check_incomplete，仍给出当前版本", str(d))
    feed = cloud / "TianliApps/Updates" / BUNDLE / "private"
    feed.mkdir(parents=True)
    package = b"PK\x05\x06" + bytes(18)

    def release(version: str, build: str, data: bytes = package):
        (feed / "FitCoach.zip").write_bytes(package)
        (feed / "release.json").write_text(json.dumps({
            "version": version, "build": build, "bundle_id": BUNDLE, "channel": "private", "installation": "manual-bundle",
            "filename": "FitCoach.zip", "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data)}))

    release("1.0.1", "6")
    _, d = run("update", "check", "--json")
    check(d.get("state") == "up_to_date" and d.get("update_available") is False and d.get("upgrade", {}).get("command") is None, "同版 → up_to_date", str(d))
    _, d = run("update", "install", "--yes", "--json")
    check(d.get("installed") is False and d.get("state") == "up_to_date", "没有新版时 update install 退出 0，installed 为 false", str(d))
    release("1.0.2", "7")
    _, d = run("update", "check", "--json")
    check(d.get("state") == "update_available" and d.get("latest", {}).get("version") == "1.0.2"
          and d.get("upgrade", {}).get("command") == "fitcoach update install --yes" and d.get("upgrade", {}).get("in_app") is False, "有新版 → update_available，给出升级命令", str(d))
    _, d = run("update", "install", "--json", expect=2)
    check(code(d) == "confirmation_required", "update install 缺 --yes → confirmation_required", str(d))
    _, d = run("update", "install", "--dry-run", "--json")
    check(d.get("dry_run") is True and d.get("would_install", {}).get("to", {}).get("version") == "1.0.2" and d.get("will_quit_app") is False, "--dry-run 只说会做什么", str(d))
    _, d = run("update", "install", "--yes", "--json", expect=1)
    check(code(d) == "manual_install" and d.get("package_verified") is True and d.get("package", "").endswith("FitCoach.zip") and d.get("installed") is False,
          "有新版 --yes → 核对发行包后以 manual_install 给出位置，不替换 App", str(d))
    release("1.0.2", "7", data=b"another package")
    _, d = run("update", "install", "--yes", "--json", expect=1)
    check(code(d) == "upgrade_failed", "发行包与记录的大小 / SHA256 不符 → upgrade_failed", str(d))
    _, d = run("update", "nope", "--json", expect=2)
    check(code(d) == "usage", "update 未知子命令 → usage", str(d))

    print("app logout / saved-login")
    _, d = run("app", "logout", "--json", expect=2)
    check(code(d) == "confirmation_required", "app logout 缺 --yes → confirmation_required", str(d))
    _, d = run("app", "logout", "--yes", "--json")
    check(d.get("logged_out") is True and d.get("had_session") is False and d.get("session_left") is False, "没有登录时 app logout 退出 0，未改动", str(d))
    seeded = False
    try:
        # 预置的是测试域（BUNDLE 已核对过不是正式 bundle id）里的假登录态。
        for key, value in (("fitcoach.coachCookie", "test-cookie"), ("fitcoach.coachEmail", "coach@example.com"), ("fitcoach.studentToken", "test-student")):
            subprocess.run(["/usr/bin/defaults", "write", BUNDLE, key, value], check=True, capture_output=True, timeout=20)
        seeded = True
    except (subprocess.SubprocessError, OSError):
        seeded = False
    if seeded:
        _, d = run("app", "logout", "--yes", "--json")
        if d.get("had_session") is True:
            check(d.get("session_left") is False and d.get("student_link_kept") is True, "有登录时 app logout 清掉教练会话，学员链接照留", str(d))
            _, d = run("app", "logout", "--yes", "--json", label="再跑一次 app logout → 退出 0")
            check(d.get("had_session") is False, "另起进程读回：教练会话已经没有了", str(d))
        else:
            check(False, "测试域里预置的登录态 App 进程读得到", str(d))
    else:
        check(False, "能在测试域里预置登录态")
    def seed() -> None:
        for key, value in (("fitcoach.coachCookie", "test-cookie"), ("fitcoach.coachEmail", "coach@example.com")):
            subprocess.run(["/usr/bin/defaults", "write", BUNDLE, key, value], check=True, capture_output=True, timeout=20)

    seed()
    run("config", "sync", "on", "--yes", "--json", label="有登录时拨开关 on → 退出 0")
    run("config", "sync", "off", "--yes", "--json", label="有登录时拨开关 off → 退出 0")
    run("config", "import", str(incoming), "--yes", "--json", label="有登录时导入同一台服务器 → 退出 0")
    _, d = run("app", "logout", "--yes", "--json", label="随后 app logout → 退出 0")
    check(d.get("had_session") is True, "只拨开关、导入同一台服务器：登录态还在", str(d))
    seed()
    elsewhere = tmp / "elsewhere.json"
    elsewhere.write_text(json.dumps({**moved, "values": {"defaults.fitcoach.baseURL": "https://other.example.org"}}))
    run("config", "import", str(elsewhere), "--yes", "--json", label="有登录时导入另一台服务器 → 退出 0")
    _, d = run("app", "logout", "--yes", "--json", label="随后 app logout → 退出 0")
    check(d.get("had_session") is False, "导入换了服务器：原服务器的登录态已清掉（App 没开着，由命令进程自己做）", str(d))
    _, d = run("app", "saved-login", "clear", "--json", expect=2)
    check(code(d) == "confirmation_required", "app saved-login clear 缺 --yes → confirmation_required", str(d))
    _, d = run("app", "saved-login", "status", "--json", expect=1)
    check(code(d) == "isolated_run", "隔离运行不读钥匙串（status → isolated_run）", str(d))
    _, d = run("app", "saved-login", "clear", "--yes", "--all", "--json", expect=1)
    check(code(d) == "isolated_run", "隔离运行不清钥匙串（clear --yes → isolated_run）", str(d))
    _, d = run("app", "saved-login", "--json", expect=2)
    check(code(d) == "usage", "app saved-login 缺子命令 → usage", str(d))
    _, d = run("app", "logout", "--yes", "--nope", "--json", expect=2)
    check(code(d) == "usage", "app 未知参数 → usage", str(d))

    print("隔离")
    drop_test_domain()
    check(not TEST_PREFS.exists(), "测试偏好域已清掉", str(TEST_PREFS))
    check(stamp(REAL_PREFS) == real_before, "正式偏好域（~/Library/Preferences 下 cyou.tianli.fitcoachapp）前后没有变化", f"{real_before} → {stamp(REAL_PREFS)}")
    check(not (tmp / "old-was-launched").exists(), "旧版 App 的可执行文件始终没有被启动")

print(f"\n{passed} 项通过，{failed} 项失败")
sys.exit(1 if failed else 0)
