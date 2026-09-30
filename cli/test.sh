#!/bin/bash
# fitcoach 命令行场景测试：隔离的本地后端（临时库，跑完删）+ 真入口 cli/fitcoach。
# 凭证目录、偏好目录都在临时目录里；线上与本机真实凭证一律不碰。ref/run 末尾会调用本脚本。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/accept/_common"
accept_start_backend
case "$FC_BASE" in
  http://127.0.0.1:*) ;;
  *) echo "FAIL: 只在本地临时后端上跑写入测试（现为 $FC_BASE）" >&2; exit 1 ;;
esac
export FITCOACH_BASE="$FC_BASE" FITCOACH_CLI_HOME="$ACCEPT_TMP/cli-home"
bash cli/build.sh
python3 cli/test_cli.py "$ACCEPT_TMP"
