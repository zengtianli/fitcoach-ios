#!/usr/bin/env python3
"""iPhone（窄屏）界面是不是还和上架时一模一样？同一份数据、两个构建、逐像素对比。

    ~/Dev/.venv/bin/python scripts/media/compact_unchanged.py [--base HEAD] [--out DIR]

App Store 的截图拍的是窄屏那套底部 TabView。2026-10-02 起同一个 target 还画宽屏（iPad / Mac / Vision Pro 的侧栏
与日程看板），并带一个手表 app，所以每次动界面都要拿出「窄屏一个像素没动」的证据。照成长小金库同名脚本：

  1. 经共享 sim_lane 编 --base 提交（默认 HEAD）与当前工作树（仓外副本、不签名的 Release 模拟器包）；
  2. 起隔离的演示后端（scripts/demo/coach_day.py：真后端 + seed.py 假数据 + 今天 4 节课，离「现在」都 ≥ 45 分钟）；
  3. 同一台 iPhone 17 Pro 模拟器（共享锁、负载门、无界面，状态栏钉在 9:41），每个构建全新安装后截 7 屏：
     登录、日程、学员、档期、更多、学员详情、体测项目；
  4. 逐像素比。一屏算「没动」：完全相同；或差异全在系统画的玻璃层里（顶部状态栏 + 导航栏玻璃按钮那条带、底部悬浮
     标签栏那条带）且任一通道差 ≤ 2 —— iOS 26 起这些玻璃会折射身后的内容，同一个包连拍两次也会差 1–2 个色阶；
     或 --control 时同一个基线包连拍两次在这一屏本身就有同量级的差（渲染噪声），且本次差异不超过那次的通道差。
     --control 多拍一轮基线包，把每屏的噪声写进报告。

退出码 0 没变 / 1 变了或失败 / 75 模拟器锁被占或机器负载高（稍后原样重跑）。--out 必须在仓外。
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUNDLE = "cyou.tianli.fitcoachapp"
sys.path.insert(0, str(Path.home() / "Dev/tools/dev/lib/tools/macapp/ios"))
import sim_lane  # noqa: E402

PY = str(Path.home() / "Dev/.venv/bin/python")
# (屏名, 额外启动参数, 是否带教练 cookie)
SCREENS = [("login", [], False),
           ("schedule", ["-fitcoach.tab", "schedule"], True),
           ("students", ["-fitcoach.tab", "students"], True),
           ("availability", ["-fitcoach.tab", "availability"], True),
           ("more", ["-fitcoach.tab", "more"], True),
           ("student", ["-fitcoach.screen", "student:1"], True),
           ("metrics", ["-fitcoach.screen", "metrics"], True)]
TOP_CHROME = 0.14     # iPhone 17 Pro 截图 2622 px 高：状态栏 + 导航栏（含右上角玻璃按钮）约 350 px，系统画的
BOTTOM_CHROME = 0.11  # 底部悬浮标签栏玻璃约 270 px，系统画的
MAX_CHROME_DIFF = 2


def sha(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def shots(udid: str, s, app: Path, base_args: list[str], cookie_args: list[str], out: Path) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    sim_lane.simctl("uninstall", udid, BUNDLE, check=False)
    s.install(app)
    hashes = {}
    for name, extra, coach in SCREENS:
        launch = [*base_args, *(cookie_args if coach else []), *extra]
        sim_lane.simctl("launch", "--terminate-running-process", udid, BUNDLE, *launch, timeout=120)
        time.sleep(9)     # 基线构建早于 lane-ready 日志：两边同样的固定等待，再等画面稳定
        a, b = out / f".{name}.a.png", out / f"{name}.png"
        s.shot(a)
        for _ in range(8):
            time.sleep(1.2)
            s.shot(b)
            if sim_lane.Frame(b, "iphone").diff(sim_lane.Frame(a, "iphone")) <= 0.0005:
                break
            shutil.copyfile(b, a)
        a.unlink(missing_ok=True)
        hashes[name] = sha(b)
        s.terminate(BUNDLE)
    sim_lane.simctl("uninstall", udid, BUNDLE, check=False)
    return hashes


def compare(a: Path, b: Path, noise: dict | None = None) -> dict:
    from PIL import Image, ImageChops
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if ia.size != ib.size:
        return {"identical": False, "ok": False, "why": f"size {ia.size} vs {ib.size}"}
    diff = ImageChops.difference(ia, ib)
    bbox = diff.getbbox()
    if bbox is None:
        return {"identical": True, "ok": True, "diff_pixels": 0}
    pixels = sum(1 for v in diff.convert("L").get_flattened_data() if v)
    top, bottom = int(ia.size[1] * TOP_CHROME), int(ia.size[1] * (1 - BOTTOM_CHROME))
    content = diff.crop((0, top, ia.size[0], bottom))
    in_content = content.getbbox()
    content_pixels = sum(1 for v in content.convert("L").get_flattened_data() if v) if in_content else 0
    peak = max(hi for _, hi in diff.getextrema())
    out = {"identical": False, "diff_pixels": pixels, "diff_bbox": list(bbox), "max_channel_diff": peak,
           "content_diff_pixels": content_pixels}
    if in_content is None and peak <= MAX_CHROME_DIFF:
        return {**out, "ok": True, "why": "system glass only (status/navigation bar, tab bar), max diff <= 2"}
    if noise and not noise.get("identical") and peak <= (noise.get("max_channel_diff") or 0):
        return {**out, "ok": True, "why": f"within same-build rendering noise ({noise.get('diff_pixels')} px, "
                                          f"max {noise.get('max_channel_diff')})"}
    return {**out, "ok": False, "why": "differs in app content" if in_content else f"glass band differs by {peak}"}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="HEAD", help="现有截图最后对照的提交")
    ap.add_argument("--out", type=Path, help="截图与报告放这里（仓外）；缺省临时目录")
    ap.add_argument("--control", action="store_true", help="基线包再拍一轮，量同一个包的渲染噪声")
    a = ap.parse_args(argv)
    base = subprocess.run(["git", "-C", str(REPO), "rev-parse", a.base], capture_output=True, text=True,
                          check=True).stdout.strip()
    work = Path(tempfile.mkdtemp(prefix="fitcoach-compact."))
    out = (a.out or work / "out").expanduser().resolve()
    if out == REPO or out.is_relative_to(REPO):
        print("--out 必须在仓外", file=sys.stderr)
        return 2
    started = dt.datetime.now().astimezone()
    demo = work / "demo"
    try:
        src_base = work / "base-src"
        src_base.mkdir()
        tar = subprocess.run(["git", "-C", str(REPO), "archive", base], capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", str(src_base)], input=tar, check=True)
        built = {"base": sim_lane.build(src_base, "FitCoach", "iphone", "Release", work / "base"),
                 "current": sim_lane.build(REPO, "FitCoach", "iphone", "Release", work / "current")}
        r = subprocess.run([PY, str(REPO / "scripts/demo/coach_day.py"), "start", "--dir", str(demo), "--json"],
                           capture_output=True, text=True, timeout=600)
        if r.returncode:
            raise SystemExit(f"演示后端没起来：{(r.stderr or r.stdout)[-300:]}")
        fixture = json.loads(r.stdout)
        base_args = ["-fitcoach.baseURL", fixture["url"]]
        cookie_args = ["-fitcoach.coachCookie", fixture["cookie"]]
        dev = sim_lane.ensure_device("iphone", "iPhone-17-Pro")
        hashes = {}
        try:
            with sim_lane.Session("iphone", dev["udid"], label="fitcoach compact_unchanged") as s:
                sim_lane.simctl("status_bar", dev["udid"], "override", "--time", "9:41", "--dataNetwork", "wifi",
                                "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active",
                                "--cellularBars", "4", "--batteryState", "charged", "--batteryLevel", "100", check=False)
                sides = ("base", "current") + (("control",) if a.control else ())
                for side in sides:
                    app = Path(built["base" if side == "control" else side]["app_path"])
                    hashes[side] = shots(dev["udid"], s, app, base_args, cookie_args, out / side)
        finally:
            subprocess.run([PY, str(REPO / "scripts/demo/coach_day.py"), "stop", "--dir", str(demo)],
                           capture_output=True)
    except sim_lane.Busy as exc:
        print(f"推迟：{exc}", file=sys.stderr)
        return 75
    noise = {name: compare(out / "base" / f"{name}.png", out / "control" / f"{name}.png")
             for name, _, _ in SCREENS} if a.control else {}
    screens = {name: {**compare(out / "base" / f"{name}.png", out / "current" / f"{name}.png", noise.get(name)),
                      "base_sha256": hashes["base"][name], "current_sha256": hashes["current"][name],
                      **({"same_build_noise": {k: noise[name].get(k) for k in ("identical", "diff_pixels",
                                                                                "max_channel_diff")}} if noise else {})}
               for name, _, _ in SCREENS}
    unchanged = all(v["ok"] for v in screens.values())
    report = {"schema_version": 1, "app": "fitcoach-ios", "checked_at": started.isoformat(timespec="seconds"),
              "base_commit": base, "current": "working tree",
              "device": f"{dev['name']} ({dev['device_type']}) / {dev['runtime'].rsplit('.', 1)[-1]} simulator",
              "builds": {k: {x: v.get(x) for x in ("version", "build", "executable_sha256", "sdk")}
                         for k, v in built.items()},
              "data": "isolated demo backend (scripts/demo/coach_day.py: real service + seed.py fictional data), "
                      "same fixture for both builds, status bar 9:41",
              "rule": f"identical; or differences only in the system glass bands (top {TOP_CHROME:.0%}: status + "
                      f"navigation bar, bottom {BOTTOM_CHROME:.0%}: tab bar) with max channel diff <= {MAX_CHROME_DIFF}; "
                      "or (--control) no larger than the same base build shot twice",
              "screens": screens, "unchanged": unchanged}
    (out / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    shutil.rmtree(work / "base", ignore_errors=True)
    shutil.rmtree(work / "current", ignore_errors=True)
    print(json.dumps({"unchanged": unchanged, "out": str(out),
                      "screens": {k: ("identical" if v.get("identical") else "ok" if v["ok"] else v.get("why"))
                                  for k, v in screens.items()}}, ensure_ascii=False))
    print(json.dumps({k: {x: v.get(x) for x in ("diff_pixels", "content_diff_pixels", "max_channel_diff", "why",
                                                 "same_build_noise")} for k, v in screens.items()}, ensure_ascii=False))
    return 0 if unchanged else 1


if __name__ == "__main__":
    sys.exit(main())
