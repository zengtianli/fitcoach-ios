#!/usr/bin/env python3
"""反向验证设备探测:**两个方向都验**。
不能只验「没插时报没插」—— 必须验「插上时认得出来」,否则用户插上手机脚本仍说没有,
人就卡死在一个看起来很合理的错误信息上。

被测对象是 detect_device.py 这个**真模块**,不是抄一份逻辑过来测 ——
抄一份测的是替身,替身永远绿而真身可以已经错了。
"""
import json, subprocess, sys, tempfile, os, pathlib

MOD = str(pathlib.Path(__file__).resolve().parent / "detect_device.py")


def dev(ident, dtype, tunnel, mkt=None, reality="physical"):
    return {"identifier": ident,
            "hardwareProperties": {"deviceType": dtype, "marketingName": mkt,
                                   "platform": "iOS", "reality": reality},
            "connectionProperties": {"tunnelState": tunnel, "pairingState": "paired"}}

CASES = [
    ("真实现状:3 台全 unavailable",
     [dev("IPAD-1","iPad","unavailable","iPad Pro"), dev("PHONE-1","iPhone","unavailable"),
      dev("IPAD-2","iPad","unavailable","iPad Air")], ""),
    ("★iPhone 已连(connected) → 必须认出",
     [dev("IPAD-1","iPad","unavailable","iPad Pro"), dev("PHONE-1","iPhone","connected"),
      dev("IPAD-2","iPad","unavailable","iPad Air")], "PHONE-1"),
    ("★iPhone 已连(available) → 也要认出",
     [dev("PHONE-1","iPhone","available")], "PHONE-1"),
    ("只有 iPad 连着 → 不能误认成 iPhone",
     [dev("IPAD-1","iPad","connected","iPad Pro")], ""),
    ("iPad 连着 + iPhone 也连着 → 挑 iPhone",
     [dev("IPAD-1","iPad","connected","iPad Pro"), dev("PHONE-1","iPhone","connected")], "PHONE-1"),
    ("deviceType 空但 marketingName 写了 iPhone",
     [dev("PHONE-2","","connected","iPhone 15 Pro Max")], "PHONE-2"),
    ("空列表 → 空",  [], ""),
    # ↓ 2026-08-18 实测踩到的:手机拔线后,脚本挑走了模拟器,一路编到「找不到 .app」才炸。
    ("★只有模拟器 → 绝不能挑它",
     [dev("SIM-1","iPhone","disconnected","iPhone 17 Pro", reality="simulated")], ""),
    ("★真机 unavailable + 模拟器在 → 仍是空",
     [dev("PHONE-1","iPhone","unavailable"),
      dev("SIM-1","iPhone","disconnected","iPhone 17 Pro", reality="simulated")], ""),
    ("真机连着 + 模拟器在 → 挑真机",
     [dev("SIM-1","iPhone","disconnected","iPhone 17 Pro", reality="simulated"),
      dev("PHONE-1","iPhone","connected")], "PHONE-1"),
    ("真机 disconnected → 不算可用",
     [dev("PHONE-1","iPhone","disconnected")], ""),
]

fails = []
for desc, devs, want in CASES:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"result": {"devices": devs}}, f); path = f.name
    r = subprocess.run([sys.executable, MOD, path], capture_output=True, text=True)
    got = (r.stdout.split() or [""])[0]   # 模块多打了名字与系统版本,只比 identifier
    os.unlink(path)
    ok = got == want
    print(f"{'✅' if ok else '❌'} 得到={got or '<空>':<9} 期望={want or '<空>':<9} {desc}")
    if not ok: fails.append(desc)

print()
if fails:
    print(f"❌ {len(fails)}/{len(CASES)} 不符：" + " | ".join(fails)); sys.exit(1)
print(f"✅ {len(CASES)}/{len(CASES)} 全部符合")
