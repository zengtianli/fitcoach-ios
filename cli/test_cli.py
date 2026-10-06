#!/usr/bin/env python3
"""fitcoach 命令行场景测试。由 cli/test.sh 调用：环境里已有隔离后端 FITCOACH_BASE 与临时 FITCOACH_CLI_HOME。

每条断言都走真入口 cli/fitcoach（与 ~/.local/bin/fitcoach 同一个文件），覆盖：
退出码协议、--json 形状、先读现值再整条提交（is_active / 地点 / 到期日 / 单价 / 方向不被清掉）、
409 需 --force、400 硬拒、学员链接不默认外露、快速开始跨进程续补、账号级写操作的确认门。
"""
from __future__ import annotations

import datetime as dt
import json
import os
import stat
import subprocess
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# 默认测仓库入口；FITCOACH_TEST_CLI 可换成 Mac 包里内嵌的那份（…/FitCoach.app/Contents/Resources/bin/fitcoach）
CLI = os.environ.get("FITCOACH_TEST_CLI") or str(ROOT / "cli" / "fitcoach")
SCRATCH = Path(sys.argv[1])
BASE = os.environ["FITCOACH_BASE"]
HOME = Path(os.environ["FITCOACH_CLI_HOME"])
assert BASE.startswith("http://127.0.0.1:"), BASE

passed = failed = 0


def check(ok: bool, label: str, detail: str = "") -> bool:
    global passed, failed
    if ok:
        passed += 1
        print(f"  ✅ {label}")
    else:
        failed += 1
        print(f"  ❌ {label}" + (f"\n     {detail.strip()[:600]}" if detail else ""))
    return ok


def run(*args: str, stdin: str | None = None, expect: int = 0, json_out: bool = True, label: str | None = None):
    cmd = [CLI, *args] + (["--json"] if json_out else [])
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=120,
                       stdin=None if stdin is not None else subprocess.DEVNULL)
    data = None
    if json_out and p.stdout.strip():
        try:
            data = json.loads(p.stdout)
        except ValueError:
            data = None
    name = label or " ".join(args)
    ok = p.returncode == expect
    if ok and json_out:
        ok = isinstance(data, dict) and data.get("ok") is (expect == 0)
    check(ok, f"{name} → exit {p.returncode}", f"want {expect}; stdout={p.stdout[:400]} stderr={p.stderr[:400]}")
    return data if data is not None else {}


def section(title: str) -> None:
    print(f"\n── {title}")


PW = "Passw0rd!234"
PW2 = "N3wPassw0rd!567"
EMAIL = "cli-agent@example.com"

section("帮助与用法")
for group in ["", "login", "logout", "status", "register", "password", "account", "schedule", "students",
              "sessions", "packages", "locations", "availability", "metrics", "growth", "measurements",
              "audit", "student-view", "setup"]:
    args = [group, "--help"] if group else ["--help"]
    p = subprocess.run([CLI, *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    check(p.returncode == 0 and "用法" in p.stdout, f"fitcoach {group} --help → 0".replace("  ", " "))
# 顶层帮助给智能体的四样：读命令与写命令、--json 形状、退出码表、仅在窗口中的项（project.yaml sop.agent_cli 的 human 项）
p = subprocess.run([CLI, "--help"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
top = p.stdout
for needle in ("读命令", "写命令", '{"ok": true', '{"ok": false, "code"', "退出码", "仅在窗口中", "暂无命令"):
    check(needle in top, f"顶层帮助有「{needle}」")
for code in range(8):
    check(any(line.strip().startswith(f"{code}  ") for line in top.splitlines()), f"退出码表有 {code}")
for sub in ("login", "logout", "status", "schedule", "students", "sessions", "packages", "locations", "availability",
            "metrics", "growth", "measurements", "audit", "setup", "password", "register", "account", "phone",
            "student-view"):
    check(any(line.strip().split(" ")[0] == sub for line in top.splitlines()), f"顶层帮助把 {sub} 列为命令（行首）")
registry = (ROOT / "project.yaml").read_text()
humans = [line.split("name:", 1)[1].strip() for line, nxt in zip(registry.splitlines(), registry.splitlines()[1:])
          if line.strip().startswith("- name:") and nxt.strip().startswith("human:")]
check(len(humans) >= 5, f"登记里读到 human 项 {len(humans)} 条")
for name in humans:
    check(name in top, f"human 项「{name}」列在帮助的「仅在窗口中」")
p = subprocess.run([CLI, "--version"], capture_output=True, text=True, timeout=60)
check(p.returncode == 0 and p.stdout.startswith("fitcoach "), "--version → 0")
d = run("bogus", expect=2)
check(d.get("code") == "usage", "未知命令 --json → {ok:false, code:usage}")
run("students", "list", "--no-such-flag", expect=2)
run("students", expect=2, label="students 缺子命令")

section("未登录")
d = run("status", expect=3)
check(d.get("code") == "signed_out", "status 未登录 → code signed_out")
run("schedule", expect=3, label="schedule 未登录")
run("login", "--email", EMAIL, stdin=None, expect=2, label="login 非终端且无 --password-stdin → 用法错")

section("注册 / 登录 / 凭证文件")
d = run("register", "--email", EMAIL, "--display-name", "CLI 教练", "--password-stdin", stdin=PW + "\n")
check(d.get("email") == EMAIL, "register 返回邮箱")
cred = HOME / "credentials.json"
check(cred.exists() and stat.S_IMODE(cred.stat().st_mode) == 0o600, "凭证文件 0600")
check(stat.S_IMODE(HOME.stat().st_mode) == 0o700, "凭证目录 0700")
check(PW not in cred.read_text(), "凭证文件不含密码")
d = run("status")
check(d.get("email") == EMAIL and len(d.get("today", "")) == 10, "status 给出登录邮箱与服务端今天")
TODAY = dt.date.fromisoformat(d["today"])
d = run("--json", "--base", BASE + "/", "status", json_out=False, label="通用参数写在命令前 + base 末尾斜杠")
mtime = cred.stat().st_mtime_ns
d = run("login", "--email", EMAIL, "--password-stdin", stdin="wrong-password\n", expect=6)
check(d.get("code") == "auth_failed", "错密码 → code auth_failed")
check(cred.stat().st_mtime_ns == mtime, "错密码不改动已有凭证")
run("login", "--email", EMAIL, "--password-stdin", stdin=PW + "\n")

section("快速开始（与 App 同一份 QuickSetup 编排）")
d = run("setup", "--location", "健身房", "--days", "weekdays")
LOC = d.get("created_location_id")
check(isinstance(LOC, int), "setup 新建地点")
check(d.get("seeded_metrics", 0) > 0, "setup 导入常用体测项目")
check(d.get("added_weekdays") == [1, 2, 3, 4, 5], "setup 补上工作日档期")
d = run("setup", "--location", "健身房", "--days", "weekdays", label="setup 再跑一次")
check(d.get("created_location_id") is None and d.get("seeded_metrics") == 0 and d.get("added_weekdays") == [],
      "setup 可重入：第二次一项不补")
avail = run("availability", "show")
wed = [r for r in avail["rules_by_wd"]["3"]]
check(len(wed) == 1, "周三一条 09:00–18:00 规则")
run("availability", "rm-rule", str(wed[0]["id"]), label="模拟中途失败：删掉周三规则")
d = run("setup", "--days", "weekdays", label="setup 跨进程续补")
check(d.get("added_weekdays") == [3] and d.get("kept_existing_availability") is False,
      "setup 只补上缺的周三（不靠进程内存）")
run("setup", "--days", "sometimes", expect=2, label="setup --days 非法值")

section("地点（先读现值再整条提交）")
d = run("locations", "update", str(LOC), "--address", "人民路 1 号")
locs = {x["id"]: x for x in run("locations", "list")["locations"]}
check(locs[LOC]["is_active"] == 1 and locs[LOC]["name"] == "健身房" and locs[LOC]["address"] == "人民路 1 号",
      "只改地址：名称保留、仍启用")
run("locations", "update", str(LOC), "--inactive")
locs = {x["id"]: x for x in run("locations", "list")["locations"]}
check(locs[LOC]["is_active"] == 0 and locs[LOC]["address"] == "人民路 1 号", "停用：地址保留")
run("locations", "update", str(LOC), "--active")
run("locations", "update", str(LOC), expect=2, label="locations update 无字段 → 用法错")
run("locations", "update", "999999", "--name", "x", expect=7, label="locations update 不存在 → 7")
d = run("locations", "add", "--name", "公园", "--address", "")
check(isinstance(d.get("id"), int), "locations add 返回 id")

section("学员与链接")
d = run("students", "add", "--name", "测试甲", "--note", "左膝旧伤")
SID = d["id"]
run("students", "update", str(SID), "--note", "已恢复")
lst = run("students", "list")
check(any(r["id"] == SID for r in lst["rows"]), "只改备注：仍在读（is_active 没被清掉）")
show = run("students", "show", str(SID))
check(show["student"]["note"] == "已恢复" and show["student"]["name"] == "测试甲", "备注已改、姓名保留")
found = run("students", "list", "--find", "测试")
check([r["id"] for r in found["rows"]] == [SID] and found.get("find") == "测试", "students list --find 按姓名筛出这一位")
none = run("students", "list", "--find", "查无此人")
check(none["rows"] == [] and none["inactive"] == [] and none["ok"] is True, "--find 查无结果 → 退出 0、两组皆空")
check(set(found) - {"find"} == set(lst), "--find 只多一个 find 键，其余字段与不筛选时一致")
run("students", "update", str(SID), expect=2, label="students update 无字段 → 用法错")
run("students", "show", "999999", expect=7, label="students show 不存在 → 7")
d = run("students", "link", str(SID))
check(d.get("has_link") is False and "link_url" not in d, "link：没有链接、不带 link_url 键")
d = run("students", "issue-link", str(SID))
check(d.get("issued") is True and "link_url" not in d, "issue-link 签发，默认不输出 URL")
d = run("students", "issue-link", str(SID), "--reveal")
check(d.get("issued") is False and str(d.get("link_url", "")).startswith(BASE + "/s/"), "已有链接不重发；--reveal 才给 URL")
URL1 = d["link_url"]
d = run("students", "link", str(SID))
check(d.get("has_link") is True and "link_url" not in d, "link 默认只报 has_link")
view = run("student-view", "--token-stdin", stdin=URL1 + "\n")
want = {"student_name", "available_total", "lapsed_total", "over_used", "packages", "next_session", "history",
        "upcoming_cancelled", "today", "growth"}
check(want <= set(view) and view.get("student_name") == "测试甲", "student-view 读到学员端 10 键视图")
check("note" not in json.dumps(view, ensure_ascii=False) or "左膝" not in json.dumps(view, ensure_ascii=False),
      "学员端视图不含教练备注")
d = run("students", "issue-link", str(SID), "--replace", "--reveal")
URL2 = d.get("link_url", "")
check(d.get("replaced") is True and URL2 and URL2 != URL1, "--replace 换发新链接")
d = run("student-view", "--token-stdin", stdin=URL1 + "\n", expect=3, label="旧链接 student-view")
check(d.get("code") == "link_invalid", "换发后旧链接 → link_invalid")
run("students", "revoke-link", str(SID), expect=4, label="revoke-link 缺理由 → 后端 400")
run("students", "revoke-link", str(SID), "--reason", "测试吊销")
run("student-view", "--token-stdin", stdin=URL2 + "\n", expect=3, label="吊销后 student-view")
run("students", "issue-link", str(SID))
d = run("students", "update", str(SID), "--inactive")
check(d.get("revoked") is True and d.get("warning"), "停用学员同时吊销链接，并给出 warning")
lst = run("students", "list")
check(any(r["id"] == SID for r in lst["inactive"]), "停用后在 inactive 组")
run("students", "update", str(SID), "--active")

section("课包")
expires = (TODAY + dt.timedelta(days=90)).isoformat()
d = run("packages", "add", "--student", str(SID), "--total", "10", "--price-yuan", "300", "--expires", expires)
PKG = d["id"]
show = run("students", "show", str(SID))
check(show["totals"]["available_total"] == 10, "新课包：可用 10 节")
run("packages", "edit", str(PKG), "--note", "暑期班")
pkg = [p for p in run("students", "show", str(SID))["buckets"]["active"] if p["package_id"] == PKG][0]
check(pkg["note"] == "暑期班" and pkg["expires_on"] == expires and pkg["unit_price_cents"] == 30000
      and pkg["total_sessions"] == 10, "只改备注：到期日、单价、节数都保留（不走 --student 也能找到）")
d = run("packages", "edit", str(PKG), "--total", "12", "--student", str(SID), expect=4,
        label="改节数不带理由 → 后端 400")
run("packages", "edit", str(PKG), "--total", "12", "--reason", "加购", "--reason-code", "other")
run("packages", "edit", str(PKG), "--reason-code", "nonsense", "--note", "x", expect=2, label="非法 reason-code → 用法错")
run("packages", "edit", "999999", "--note", "x", expect=7, label="packages edit 不存在 → 7")
run("packages", "add", "--student", str(SID), "--total", "5", "--expires", "2026-02-30", expect=2,
    label="packages add 非法日期 → 用法错")

section("课次：排课、软警告、硬拒、改课、改状态")
future = TODAY + dt.timedelta(days=2)
while future.weekday() >= 5:
    future += dt.timedelta(days=1)
F = future.isoformat()
opts = run("sessions", "options", "--student", str(SID), "--date", F)
check(any(p["package_id"] == PKG for p in opts.get("packages", [])), "options 列出该学员课包")
check(len(opts.get("windows", [])) >= 1, "options 给出当天可排时段")
d = run("sessions", "add", "--package", str(PKG), "--start", f"{F} 10:00", "--minutes", "60", "--location", str(LOC))
S1 = d["id"]
check(d.get("end_at") == f"{F} 11:00", "--minutes 60 → 结束 11:00")
d = run("sessions", "add", "--package", str(PKG), "--start", f"{F} 10:30", "--end", "11:30", expect=5,
        label="同时段再排")
check(d.get("code") == "needs_force" and any(w["code"] == "conflict" for w in d.get("warnings", [])),
      "冲突 → 409 needs_force，warnings 带 conflict")
d = run("sessions", "add", "--package", str(PKG), "--start", f"{F} 10:30", "--end", "11:30", "--force")
S2 = d["id"]
day = [g for g in run("schedule", "--range", "today", "--date", F)["days"] if g["date_"] == F]
check(len(day) == 1 and len(day[0]["sessions"]) == 2, "--force 后当天恰好两节")
run("sessions", "add", "--package", str(PKG), "--start", f"{F} 10:00", expect=2, label="缺 --end/--minutes → 用法错")
run("sessions", "add", "--package", str(PKG), "--start", f"{F}T10:00", "--minutes", "30", expect=2,
    label="时间格式不对 → 用法错")
d = run("sessions", "status", str(S1), "--to", "completed", expect=4, label="未来的课标已上课")
check("未来" in d.get("error", ""), "future_done 硬拒 → 400（--force 也不放行）")
run("sessions", "status", str(S1), "--to", "completed", "--force", expect=4, label="硬拒加 --force 仍拒")
run("sessions", "status", str(S1), "--to", "done", expect=2, label="未知状态 → 用法错")
d = run("sessions", "edit", str(S1), "--content", "热身", expect=5, label="改课仍与另一节重叠")
check(d.get("code") == "needs_force", "改课同样走 409 软警告")
run("sessions", "edit", str(S2), "--start", f"{F} 14:00")
s2 = run("sessions", "show", str(S2))["session"]
check(s2["start_at"] == f"{F} 14:00" and s2["end_at"] == f"{F} 15:00", "只改开始：保持原时长")
run("sessions", "edit", str(S2), "--content", "核心力量")
s2 = run("sessions", "show", str(S2))["session"]
check(s2["content"] == "核心力量" and s2["location_id"] is None and s2["start_at"] == f"{F} 14:00"
      and s2["end_at"] == f"{F} 15:00", "只改内容：时间与（空）地点不变")
run("sessions", "edit", str(S1), "--content", "热身")
s1 = run("sessions", "show", str(S1))["session"]
check(s1["location_id"] == LOC and s1["content"] == "热身" and s1["end_at"] == f"{F} 11:00",
      "只改内容：地点、时间保留（后端缺字段会清空）")
run("sessions", "edit", str(S1), "--no-location")
check(run("sessions", "show", str(S1))["session"]["location_id"] is None, "--no-location 清空地点")
run("sessions", "edit", str(S1), expect=2, label="sessions edit 无字段 → 用法错")
past = TODAY - dt.timedelta(days=3)
P = past.isoformat()
d = run("sessions", "add", "--package", str(PKG), "--start", f"{P} 10:00", "--minutes", "60", expect=5,
        label="过去时间排课")
d = run("sessions", "add", "--package", str(PKG), "--start", f"{P} 10:00", "--minutes", "60", "--force")
S3 = d["id"]
before = run("students", "show", str(SID))["totals"]["available_total"]
run("sessions", "status", str(S3), "--to", "completed")
after = run("students", "show", str(SID))["totals"]["available_total"]
check(after == before - 1, f"标已上课扣 1 节（{before} → {after}）")
run("sessions", "status", str(S3), "--to", "scheduled", expect=4, label="从已上课改回不带理由 → 400")
run("sessions", "status", str(S3), "--to", "scheduled", "--reason", "记错了", "--reason-code", "mistake")
shown = run("sessions", "show", str(S3))
check(shown.get("history_complete") is True and any(h["field"] == "status" for h in shown.get("history", [])),
      "sessions show 带这一节的状态变更记录")
run("sessions", "show", "999999", expect=7, label="sessions show 不存在 → 7")
aud = run("audit")
check(aud.get("capped") is False and any(r["entity_id"] == S3 for r in aud.get("rows", [])), "audit 默认列纠错类")
aud_all = run("audit", "--all", "--student", str(SID))
check(len(aud_all.get("rows", [])) >= len(aud.get("rows", [])), "audit --all --student 行数不少于纠错类")

section("作废课包（与 App 作废页一样要确认）")
pending = [x for x in run("students", "show", str(SID))["sessions"]
           if x["package_id"] == PKG and x["status"] == "scheduled"]
d = run("packages", "void", str(PKG), "--reason", "退课", "--reason-code", "student_leave", expect=5,
        label="packages void 不带 --yes")
check(d.get("code") == "needs_confirm", "作废不带 --yes → needs_confirm")
still = [x for x in run("students", "show", str(SID))["sessions"]
         if x["package_id"] == PKG and x["status"] == "scheduled"]
check(len(still) == len(pending), "未确认时一节课都没被取消")
d = run("packages", "void", str(PKG), "--dry-run")
check(d.get("dry_run") is True and d.get("would_cancel") == len(pending) and d.get("already_voided") is False,
      f"--dry-run 报出将取消 {len(pending)} 节（只读）")
run("packages", "void", "999999", "--dry-run", expect=7, label="void --dry-run 不存在 → 7")
d = run("packages", "void", str(PKG), "--yes", "--reason", "退课", "--reason-code", "student_leave")
check(d.get("cancelled") == len(pending) >= 2 and d.get("warning"),
      f"作废一并取消包内 {len(pending)} 节已排课")
d = run("packages", "void", str(PKG), "--dry-run", "--student", str(SID))
check(d.get("already_voided") is True and d.get("would_cancel") == 0, "作废后 --dry-run：已作废、无可取消")
run("packages", "void", "999999", "--yes", "--reason", "x", expect=4, label="直接作废不存在的 id → 后端 400（不是 7）")
run("packages", "void", str(PKG), "--undo", "--reason", "恢复")

section("体测项目 / 测量 / 成长")
run("metrics", "add", "--name", "仰卧起坐", "--unit", "次", expect=2, label="metrics add 不给方向 → 用法错")
run("metrics", "add", "--name", "x", "--higher-is-better", "--lower-is-better", expect=2, label="方向两个都给 → 用法错")
d = run("metrics", "add", "--name", "800 米跑", "--unit", "秒", "--lower-is-better", "--sort", "9")
M = d["id"]
m = {x["id"]: x for x in run("metrics", "list")["metrics"]}[M]
check(m["higher_is_better"] == 0, "新建「越小越好」存成 0（新建端点默认 1，空串会被套默认值）")
run("metrics", "update", str(M), "--name", "800米")
m = {x["id"]: x for x in run("metrics", "list")["metrics"]}[M]
check(m["higher_is_better"] == 0 and m["sort_order"] == 9 and m["unit"] == "秒" and m["is_active"] == 1,
      "只改名称：方向（越小越好）、排序、单位、启用都保留")
check(run("metrics", "seed").get("created") == 0, "seed 已有项目时不重复导入")
M0 = [x for x in run("metrics", "list")["metrics"] if x["higher_is_better"] == 1][0]["id"]
D1 = (TODAY - dt.timedelta(days=10)).isoformat()
run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--date", D1, "--value", "100")
d = run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--date", D1, "--value", "110")
MID = d["id"]
g = run("growth", str(SID), "--metric", str(M0))
same_day = [x for x in g.get("measurements", []) if x["taken_on"] == D1]
check(len(same_day) == 1 and same_day[0]["value"] == 110, "同一天再记 = 覆盖为后值")
check(g.get("metric_filter") == M0 and all(p["metric_id"] == M0 for p in g.get("progress", [])),
      "growth --metric 本地筛选")
run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--value", "abc", expect=4,
    label="非数值 → 后端 400")
run("measurements", "add", "--student", str(SID), "--metric", str(M0), expect=2, label="缺 --value → 用法错")
d = run("measurements", "rm", str(MID), expect=5, label="measurements rm 不带 --yes")
check(d.get("code") == "needs_confirm", "删测量不带 --yes → needs_confirm")
d = run("measurements", "rm", str(MID), "--dry-run")
check(d.get("dry_run") is True and (d.get("would_delete") or {}).get("id") == MID
      and (d.get("would_delete") or {}).get("value") == 110, "--dry-run 报出将删的那条测量（只读）")
check(any(x["id"] == MID for x in run("growth", str(SID))["measurements"]), "未确认时测量仍在")
run("measurements", "rm", "999999", "--dry-run", "--student", str(SID), expect=7, label="rm --dry-run 不存在 → 7")
run("measurements", "rm", str(MID), "--yes")
run("measurements", "rm", str(MID), "--yes", expect=4, label="重复删除 → 后端 400")

section("小数原样输出（不出现 12.300000000000001）")
D2 = (TODAY - dt.timedelta(days=5)).isoformat()
D3 = (TODAY - dt.timedelta(days=4)).isoformat()
run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--date", D2, "--value", "12.3")
run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--date", D3, "--value", "65.4")
D4 = (TODAY - dt.timedelta(days=3)).isoformat()
run("measurements", "add", "--student", str(SID), "--metric", str(M0), "--date", D4, "--value", "70")
p = subprocess.run([CLI, "growth", str(SID), "--json"], capture_output=True, text=True,
                   stdin=subprocess.DEVNULL, timeout=120)
literals: list[str] = []
cli_doc = json.loads(p.stdout, parse_float=lambda s: literals.append(s) or float(s))
check(p.returncode == 0 and '":12.3' in p.stdout and "12.300000000000001" not in p.stdout
      and "65.400000000000006" not in p.stdout and '":70.0' in p.stdout, "growth --json 写 12.3 / 65.4 / 70.0",
      p.stdout[:400])
bad = [s for s in literals if repr(float(s)) != s]
check(literals and not bad, f"--json 里的小数都是最短往返写法（{len(literals)} 个）", str(bad[:5]))
cookie = json.loads(cred.read_text())["accounts"][BASE]["cookie"]
req = urllib.request.Request(f"{BASE}/coach/api/students/{SID}/growth", headers={"Cookie": f"fc_coach={cookie}"})
raw_text = urllib.request.urlopen(req, timeout=30).read().decode()
raw_literals: list[str] = []
raw_doc = json.loads(raw_text, parse_float=lambda s: raw_literals.append(s) or float(s))
cli_doc.pop("ok", None)
check(cli_doc == raw_doc and sorted(literals) == sorted(raw_literals),
      f"growth --json 与后端原始响应逐字段相同，小数原文一致（{len(raw_literals)} 个）",
      f"cli-only={sorted(set(literals) - set(raw_literals))[:5]} raw-only={sorted(set(raw_literals) - set(literals))[:5]}")

section("档期")
d = run("availability", "add-rule", "--weekday", "6", "--start", "10:00", "--end", "12:00")
R = d["id"]
d = run("availability", "rm-rule", str(R))
check((d.get("deleted") or {}).get("id") == R, "rm-rule 输出被删的规则（便于重建）")
run("availability", "rm-rule", str(R), expect=4, label="重复删除规则 → 后端 400")
run("availability", "add-rule", "--weekday", "1", "--start", "9:00", "--end", "12:00", expect=2,
    label="时间不是 HH:MM → 用法错")
d = run("availability", "add-exception", "--date", F, "--kind", "block", "--reason", "出差")
E = d["id"]
d = run("setup", label="有例外时 setup")
check(d.get("kept_existing_availability") is True and d.get("added_weekdays") == [], "有自配档期时 setup 不动档期")
d = run("availability", "rm-exception", str(E))
check((d.get("deleted") or {}).get("kind") == "block", "rm-exception 输出被删的例外")

section("只读不写状态")
st = run("status")
check(st.get("version") and st.get("base") == BASE and st.get("email") == EMAIL and st.get("today"),
      "status 读回版本、服务器、账号与服务端今天")
before = cred.stat().st_mtime_ns
for args in (["status"], ["schedule", "--range", "week"], ["students", "list"], ["audit", "--all"],
             ["availability", "show"], ["metrics", "list"], ["locations", "list"]):
    run(*args)
check(cred.stat().st_mtime_ns == before, "读命令不改凭证文件")
prefs = [p for p in (SCRATCH / "preferences").rglob("*.plist")]
check(prefs == [], "命令行不写 UserDefaults（偏好目录无 plist）", str(prefs))

section("改密码 / 注销（只在临时后端）")
run("password", "--stdin", stdin=f"{PW}\n{PW2}\n")
run("login", "--email", EMAIL, "--password-stdin", stdin=PW + "\n", expect=6, label="旧密码登录")
run("login", "--email", EMAIL, "--password-stdin", stdin=PW2 + "\n", label="新密码登录")
d = run("account", "delete", expect=5, label="account delete 不带 --confirm")
check(d.get("code") == "needs_confirm", "不带字面量确认 → needs_confirm")
run("account", "delete", "--confirm", "yes", expect=5, label="确认词不对")
d = run("account", "delete", "--dry-run")
check(d.get("would_delete") is True and d.get("email") == EMAIL, "--dry-run 只报目标账号")
run("status", label="dry-run 后仍登录")
d = run("account", "delete", "--confirm", "delete-account")
check(d.get("deleted") is True, "account delete 确认后删除")
run("status", expect=3, label="注销后 status")
run("login", "--email", EMAIL, "--password-stdin", stdin=PW2 + "\n", expect=6, label="注销后登录")
d = run("logout")
check(d.get("removed") is False, "logout 没有凭证时 removed=false、退出 0")

section("服务端 5xx ≠ 后端拒绝（假服务器，不碰真后端）")


class Fake(BaseHTTPRequestHandler):
    def _reply(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        if self.path.startswith("/api/login") and "throttle%40" in body:
            status, text, kind = 429, json.dumps({"ok": False, "error": "尝试过于频繁，请 60 秒后再试"}), "application/json"
        else:
            status, text, kind = 502, "<html><body>502 Bad Gateway</body></html>", "text/html"
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = _reply

    def log_message(self, *args):
        pass


fake = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=fake.serve_forever, daemon=True).start()
FAKE = f"http://127.0.0.1:{fake.server_address[1]}"
d = run("--base", FAKE, "student-view", "--token-stdin", stdin="abc\n", expect=1, label="student-view 遇 502")
check(d.get("code") == "server_error", "502 → exit 1 server_error（可重试，不是 4 rejected）")
d = run("--base", FAKE, "login", "--email", "x@example.com", "--password-stdin", stdin="pw\n", expect=1,
        label="login 遇 502")
check(d.get("code") == "server_error", "login 遇 502 → exit 1 server_error（不是 6 登录失败）")
d = run("--base", FAKE, "login", "--email", "throttle@example.com", "--password-stdin", stdin="pw\n", expect=6,
        label="login 遇 429")
check(d.get("code") == "login_refused", "login 遇 429 仍是 6 login_refused")
fake.shutdown()

print(f"\n── 结果：{passed} 项通过，{failed} 项失败")
sys.exit(1 if failed else 0)
