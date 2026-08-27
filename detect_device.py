#!/usr/bin/env python3
"""从 `devicectl list devices --json-output` 里挑出「可以往上装 app 的那台 iPhone」。

**独立成文件是有原因的**:此前脚本里内嵌一份、测试里又抄一份,注释还写着「与
install-device.sh 里那段逐字相同」—— 那正是会漂的写法(改一处忘另一处,测试继续绿而
脚本已经错了)。现在 install-to-iphone.sh 与 test-device-detect.py 都调这个文件。

判据三条,一条都不能少(每条都是踩出来的):
  · **真机**:`hardwareProperties.reality == "physical"` —— 少这条会挑中**模拟器**。
    2026-08-18 实测:手机拔线后脚本挑走了 iPhone 17 Pro 模拟器,一路编到「找不到 .app」
    才炸,报错还指向别处。模拟器的 tunnelState 是 `disconnected` 不是 `unavailable`,
    只靠状态过滤拦不住它。
  · **状态**:排除 `unavailable` / `disconnected`;其余(connected / available)当可用 ——
    只认 `connected` 会漏掉 `available`,表现是「手机明明插着,脚本说没插」。
  · **机型**:deviceType 或 marketingName 任一含 iPhone —— 只看 deviceType,
    遇到该字段为空、只有 marketingName 的设备会漏。
用法: python3 detect_device.py <devices.json>   → stdout 打 identifier(找不到则空)
"""
import json
import sys


def pick(payload: dict) -> dict | None:
    for dev in (payload.get("result", {}) or {}).get("devices", []) or []:
        conn = dev.get("connectionProperties", {}) or {}
        hw = dev.get("hardwareProperties", {}) or {}
        if hw.get("reality") != "physical":          # 模拟器/占位一律不算
            continue
        if conn.get("tunnelState") in ("unavailable", "disconnected", None):
            continue
        blob = f"{hw.get('deviceType', '')} {hw.get('marketingName', '')}"
        if "iPhone" in blob:
            return dev
    return None


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: detect_device.py <devices.json>", file=sys.stderr)
        return 2
    try:
        payload = json.load(open(sys.argv[1]))
    except Exception as e:
        print(f"读不了 {sys.argv[1]}: {e}", file=sys.stderr)
        return 2
    dev = pick(payload)
    if dev is None:
        return 1                      # 没找到 = 非零,调用方能靠退出码判,不用猜空串
    props = dev.get("deviceProperties", {}) or {}
    print(dev.get("identifier", ""),
          (props.get("name") or "iPhone").replace(" ", "_"),
          props.get("osVersionNumber", "?"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
