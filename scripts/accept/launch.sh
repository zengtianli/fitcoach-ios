#!/bin/bash
# 平台线启动冒烟（Chapter app_sop 的 sop.accept.launch_<线>）：`scripts/accept/launch.sh <iphone|ipad|mac|watch|vision>`。
# iPhone / iPad / Mac / Vision：先起隔离的演示后端（scripts/demo/coach_day.py：真后端、127.0.0.1 随机端口、临时库、
# seed.py 假数据 + 今天 4 节课），再交给 Chapter 内置的 platform_launch（$SOP_PLATFORM_LAUNCH），带上后端地址与演示
# 教练 cookie —— 车道按 App 第一屏有数据时打的 lane-ready 判起来了没有。cookie 在证据里由 platform_launch 打码。
# 手表不联网（数据由 iPhone 递），用 -fitcoach.watchDemo 1 的占位假快照，不起后端。
# 从不碰 fit.tianli.cyou 与线上库。退出码原样透传：0 通过，75 推迟（模拟器锁被占 / 负载高），78 没有夹具，其余失败。
# 照成长小金库 scripts/accept/launch.sh（2026-10-02）。
set -uo pipefail
lane="${1:?usage: launch.sh <iphone|ipad|mac|watch|vision>}"
case "$lane" in iphone|ipad|mac|watch|vision) ;; *) echo "unknown lane $lane"; exit 2;; esac
cd "$(dirname "$0")/../.."
[ -n "${SOP_PLATFORM_LAUNCH:-}" ] || { echo "SOP_PLATFORM_LAUNCH 未设置：只能由 Chapter 的 launch_$lane 验收调用"; exit 78; }
py="$HOME/Dev/.venv/bin/python"
[ -x "$py" ] || py=python3

if [ "$lane" = watch ]; then
  "$py" "$SOP_PLATFORM_LAUNCH" --arg=-fitcoach.watchDemo --arg=1
  exit $?
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/fitcoach-launch-$lane.XXXXXX")"
cleanup() { "$py" scripts/demo/coach_day.py stop --dir "$scratch" >/dev/null 2>&1; rm -rf "$scratch"; }
trap cleanup EXIT

info="$("$py" scripts/demo/coach_day.py start --dir "$scratch" --json)"
code=$?
[ "$code" = 0 ] || { echo "演示后端没起来（退出码 ${code}）"; exit "$code"; }
read -r url cookie < <(printf '%s' "$info" | "$py" -c 'import json,sys; d=json.load(sys.stdin); print(d["url"], d["cookie"])')
echo "演示后端 ${url}（演示教练，临时库）"

"$py" "$SOP_PLATFORM_LAUNCH" --arg=-fitcoach.baseURL --arg="$url" --arg=-fitcoach.coachCookie --arg="$cookie"
exit $?
