#!/usr/bin/env python3
"""演示教练的一天：给截图、平台冒烟（sim_lane）与各平台测量用的隔离后端。

    ~/Dev/.venv/bin/python scripts/demo/coach_day.py start --dir <仓外临时目录> [--json]
    ~/Dev/.venv/bin/python scripts/demo/coach_day.py stop  --dir <同一目录>

start 在 127.0.0.1 随机端口起**真的** ~/Apps/fitcoach/service（uvicorn，FITCOACH_COACH_AUTH=multi，库在 --dir 里），
先跑后端自己的 seed.py 灌演示假数据（张三 / 李四 / 王五，seed.py 自带落库自检），再补两个假学员（赵六、孙七）
和**今天**的 4 节课：时间从固定候选里挑，离「现在」都至少 45 分钟（同一次截图对照里不会有课恰好在两张图之间
从「待上」变成「待处理」），已经结束的那几节经后端 set_session_status 记成已上课。最后用 seed 留下的未认领
演示账号（demo@example.com，pw_hash 为空）走 /api/register 认领，拿到教练 cookie 值。

stdout 一个 JSON：url、port、pid、cookie、email、password、dir、today、lessons。App 用
`-fitcoach.baseURL <url> -fitcoach.coachCookie <cookie>` 直接进教练端。

不碰 fit.tianli.cyou、线上库、~/.personal_env 或任何真实学员：名字全是占位假名，密码随机。stop 杀掉服务。
退出码 0 成功 / 1 失败 / 2 用法错 / 78 后端源码或其 venv 不在（没有夹具可起）。
"""
from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

SERVICE = Path(os.environ.get("FITCOACH_TEST_BACKEND") or Path(__file__).resolve().parents[4] / "service")
NO_FIXTURE = 78
EMAIL = "demo@example.com"      # seed.py 建的未认领演示账号

# 在后端 venv 里跑：seed.build 灌库（自带自检），再补今天的课。全部走 domain.*，与线上同一份业务判据。
SEED = r'''
import datetime, json, sys
sys.path.insert(0, ".")
import db, domain, seed

path = sys.argv[1]
seed.build(path)
conn = db.connect(path)
CID, ACTOR = seed.CID, "demo-coach-day"
locs = {r["name"]: r["id"] for r in conn.execute("SELECT id, name FROM location WHERE coach_id = ?", (CID,))}
gym, park = locs["力量工作室（城西店）"], locs["社区体育馆"]

def student_package(name, total, note, purchased_days_ago):
    sid = domain.create_student(conn, CID, name, "")
    day = domain.now_local().date() - datetime.timedelta(days=purchased_days_ago)
    return domain.create_package(conn, CID, student_id=sid, total_sessions=total, unit_price_cents=30000,
                                 purchased_on=f"{day:%Y-%m-%d}", expires_on=None, note=note)

def package_of(name):
    row = conn.execute(
        "SELECT p.id FROM package p JOIN student s ON s.id = p.student_id "
        "WHERE s.coach_id = ? AND s.name = ? AND p.voided_at IS NULL AND (p.expires_on IS NULL OR p.expires_on >= ?) "
        "ORDER BY p.id DESC LIMIT 1", (CID, name, domain.today_str())).fetchone()
    return row["id"]

zhao = student_package("赵六", 3, "体验 3 次卡", 6)
sun = student_package("孙七", 12, "12 次卡", 2)
plan = [("王五", park, "自重基础 · 髋铰链复习"), ("张三", gym, "下肢日 · 深蹲进阶"),
        ("赵六", park, "体能测试 · 立定跳远"), ("孙七", gym, "上肢日 · 推拉平衡")]
pkgs = {"王五": package_of("王五"), "张三": package_of("张三"), "赵六": zhao, "孙七": sun}

now = domain.now_local().replace(tzinfo=None, second=0, microsecond=0)
today = now.date()
def at(hhmm):
    return datetime.datetime.combine(today, datetime.time(int(hhmm[:2]), int(hhmm[3:])))
# 候选时段；离现在至少 45 分钟（开始与结束都算），尽量两节已上、两节待上
cands = ["07:30", "09:00", "10:30", "13:30", "15:00", "16:30", "18:00", "19:30", "21:00"]
margin = datetime.timedelta(minutes=45)
ok = [c for c in cands if abs(at(c) - now) >= margin and abs(at(c) + datetime.timedelta(hours=1) - now) >= margin]
past = [c for c in ok if at(c) + datetime.timedelta(hours=1) <= now]
future = [c for c in ok if at(c) > now]
n_past = min(len(past), max(2, 4 - len(future)))
pick = past[len(past) - n_past:] + future[:4 - n_past]
lessons = []
for (name, loc, content), hhmm in zip(plan, pick):
    start = at(hhmm)
    end = start + datetime.timedelta(hours=1)
    sid, warns = domain.create_session(conn, CID, package_id=pkgs[name], start_at=domain.fmt_stamp(start),
                                       end_at=domain.fmt_stamp(end), location_id=loc, content=content,
                                       status="scheduled", actor=ACTOR, reason="", reason_code=None, force=True)
    if sid is None:
        raise SystemExit(f"今天的演示课被硬拒：{[w.message for w in warns]}")
    status = "scheduled"
    if end <= now:
        domain.set_session_status(conn, CID, sid, "completed", actor=ACTOR, reason="", reason_code=None)
        status = "completed"
    lessons.append({"time": hhmm, "student": name, "status": status})
conn.close()
print("DEMO-JSON " + json.dumps({"today": f"{today:%Y-%m-%d}", "lessons": lessons}, ensure_ascii=False))
'''


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def post_form(url: str, fields: dict) -> dict:
    req = urllib.request.Request(url, method="POST", data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def start(work: Path) -> dict:
    py = SERVICE / ".venv/bin/python"
    if not (SERVICE / "seed.py").is_file() or not py.exists():
        print(f"后端源码或 venv 不在 {SERVICE}", file=sys.stderr)
        sys.exit(NO_FIXTURE)
    stop(work)
    work.mkdir(parents=True, exist_ok=True)
    data = work / "data"
    shutil.rmtree(data, ignore_errors=True)       # 每次都是同一个故事，不带上一次的残留
    data.mkdir()
    dbp = data / "demo.db"
    env = {**{k: v for k, v in os.environ.items() if not k.startswith(("FC_", "FITCOACH_"))},
           "FITCOACH_DB": str(dbp), "FITCOACH_COACH_AUTH": "multi", "PYTHONDONTWRITEBYTECODE": "1",
           "TLZ_GATE_SECRET": secrets.token_hex(32)}
    r = subprocess.run([str(py), "-c", SEED, str(dbp)], cwd=SERVICE, env=env, capture_output=True, text=True,
                       timeout=120)
    marker = [ln for ln in r.stdout.splitlines() if ln.startswith("DEMO-JSON ")]
    if r.returncode or not marker:
        raise SystemExit(f"灌演示库失败：{(r.stderr or r.stdout)[-600:]}")
    day = json.loads(marker[-1][len("DEMO-JSON "):])
    port = free_port()
    log = work / "server.log"
    proc = subprocess.Popen([str(py), "-m", "uvicorn", "api:app", "--host", "127.0.0.1", "--port", str(port),
                             "--log-level", "warning"], cwd=SERVICE, env=env, stdout=open(log, "a"),
                            stderr=subprocess.STDOUT, start_new_session=True)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(base + "/healthz", timeout=1)
                break
            except OSError:
                if proc.poll() is not None:
                    raise SystemExit(f"后端没起来，见 {log}")
                time.sleep(0.1)
        else:
            raise SystemExit(f"后端 10 秒内没就绪，见 {log}")
        pw = "Demo-" + secrets.token_hex(8)
        out = post_form(base + "/api/register", {"email": EMAIL, "password": pw, "display_name": "演示教练"})
        if not out.get("ok") or not out.get("cookie"):
            raise SystemExit(f"认领演示账号失败：{out}")
    except BaseException:
        os.killpg(proc.pid, signal.SIGTERM)
        raise
    info = {"ok": True, "url": base, "port": port, "pid": proc.pid, "cookie": out["cookie"], "email": EMAIL,
            "password": pw, "dir": str(work), **day}
    meta = work / "coach_day.json"
    meta.write_text(json.dumps(info, ensure_ascii=False), encoding="utf-8")
    os.chmod(meta, 0o600)
    return info


def stop(work: Path) -> bool:
    meta = work / "coach_day.json"
    try:
        pid = json.loads(meta.read_text(encoding="utf-8"))["pid"]
    except (OSError, ValueError, KeyError):
        return False
    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    meta.unlink(missing_ok=True)
    return True


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("start", "stop"))
    ap.add_argument("--dir", required=True, type=Path, help="仓外临时目录（库、日志、元数据都放这里）")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    work = a.dir.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if work == repo or work.is_relative_to(repo):
        print(f"--dir 必须在仓外（{work}）", file=sys.stderr)
        return 2
    if a.cmd == "stop":
        print(json.dumps({"ok": True, "stopped": stop(work)}))
        return 0
    info = start(work)
    print(json.dumps(info, ensure_ascii=False) if a.json else
          f"demo coach {info['url']} · {info['today']} · " +
          "、".join(f"{x['time']} {x['student']}" for x in info["lessons"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
