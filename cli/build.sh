#!/bin/bash
# 编 fitcoach 命令行：与 App 同一份 Sources/{Models,TimeKit,API,QuickSetup}.swift + Shared/RemoteUI.swift + cli/*.swift
# → build/cli/fitcoach（build/ 不进仓）。只编译，不装机、不签名、不碰 /Applications。
#
#   bash cli/build.sh            只编
#   bash cli/build.sh --link     再把 ~/.local/bin/fitcoach 链到仓库入口 cli/fitcoach
#                                （目标已存在且不是指向本入口的软链时拒绝覆盖）
#   bash cli/build.sh --link-app 不编；把 ~/.local/bin/fitcoach 改链到已装 Mac 版包内的
#                                Contents/Resources/bin/fitcoach（按 bundle id 找包，不猜名字）。
#                                原链接只能是本仓入口或同 bundle id 的包，否则拒绝覆盖。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="cyou.tianli.fitcoachapp"
ENTRY="$ROOT/cli/fitcoach"
DEST="$HOME/.local/bin/fitcoach"
LINK=0
LINK_APP=0
for arg in "$@"; do
  case "$arg" in
    --link) LINK=1 ;;
    --link-app) LINK_APP=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fitcoach build：不认识的参数 $arg" >&2; exit 2 ;;
  esac
done
if [ "$LINK" = 1 ] && [ "$LINK_APP" = 1 ]; then
  echo "fitcoach build：--link 与 --link-app 只能给一个" >&2
  exit 2
fi

bundle_id_of() {  # <某.app> → CFBundleIdentifier（读不出为空）
  plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

if [ "$LINK_APP" = 1 ]; then
  # 已装的同 bundle id 包里，带内嵌命令行的那一个（/Applications，写不进时安装脚本会退到 ~/Applications）
  HOSTS=()
  IFS=: read -r -a DIRS <<< "${FITCOACH_APPS_DIRS:-/Applications:$HOME/Applications}"
  for dir in "${DIRS[@]}"; do
    for app in "$dir"/*.app; do
      [ -d "$app" ] || continue
      [ "$(bundle_id_of "$app")" = "$BUNDLE_ID" ] || continue
      [ -x "$app/Contents/Resources/bin/fitcoach" ] && HOSTS+=("$app")
    done
  done
  if [ "${#HOSTS[@]}" -eq 0 ]; then
    echo "fitcoach build：没有已装的 $BUNDLE_ID 包带 Contents/Resources/bin/fitcoach —— 先重装 Mac 版（bash install-to-mac.sh --no-launch）" >&2
    exit 1
  fi
  if [ "${#HOSTS[@]}" -gt 1 ]; then
    echo "fitcoach build：有 ${#HOSTS[@]} 个同 bundle id 的包都带命令行（${HOSTS[*]}），先退役旧副本再链" >&2
    exit 1
  fi
  TARGET="${HOSTS[0]}/Contents/Resources/bin/fitcoach"
  mkdir -p "$(dirname "$DEST")"
  if [ -L "$DEST" ]; then
    OLD="$(readlink "$DEST")"
    OLD_REAL="$(cd "$(dirname "$DEST")" && realpath "$OLD" 2>/dev/null || true)"
    case "$OLD" in
      */Contents/Resources/bin/fitcoach) OLD_APP="${OLD%/Contents/Resources/bin/fitcoach}" ;;
      *) OLD_APP="" ;;
    esac
    if [ "$OLD_REAL" = "$(realpath "$ENTRY")" ]; then :            # 仓库入口 → 包内
    elif [ -n "$OLD_APP" ] && { [ ! -e "$OLD_APP" ] || [ "$(bundle_id_of "$OLD_APP")" = "$BUNDLE_ID" ]; }; then :
    else
      echo "fitcoach build：$DEST 已链到别处（$OLD），拒绝覆盖" >&2
      exit 1
    fi
  elif [ -e "$DEST" ]; then
    echo "fitcoach build：$DEST 已存在且不是软链，拒绝覆盖" >&2
    exit 1
  fi
  ln -sfn "$TARGET" "$DEST"
  echo "fitcoach build：$DEST → $TARGET" >&2
  exit 0
fi

XENV="$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh"
if [ -f "$XENV" ]; then
  # 本机舰队：与 ref/run 同一个 Xcode 选择器（失败即停，不回落 xcode-select）
  source "$XENV"
  xcode_env_use macosx >&2
else
  echo "fitcoach build：未找到舰队 xcode_env.sh，使用当前 xcrun 工具链" >&2
fi

OUT="$ROOT/build/cli"
mkdir -p "$OUT"
TMP="$OUT/.fitcoach.$$"
trap 'rm -f "$TMP"' EXIT
xcrun swiftc -O -swift-version 5 -parse-as-library -module-name FitCoachCLI \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/TimeKit.swift" "$ROOT/Sources/API.swift" \
  "$ROOT/Sources/QuickSetup.swift" "$ROOT/Shared/RemoteUI.swift" "$ROOT"/cli/*.swift \
  -o "$TMP"
mv -f "$TMP" "$OUT/fitcoach"
echo "fitcoach build：$OUT/fitcoach" >&2

if [ "$LINK" = 1 ]; then
  mkdir -p "$(dirname "$DEST")"
  if [ -L "$DEST" ]; then
    CURRENT="$(cd "$(dirname "$DEST")" && realpath "$(readlink "$DEST")" 2>/dev/null || true)"
    if [ "$CURRENT" != "$(realpath "$ENTRY")" ]; then
      echo "fitcoach build：$DEST 已链到别处（$(readlink "$DEST")），拒绝覆盖" >&2
      exit 1
    fi
  elif [ -e "$DEST" ]; then
    echo "fitcoach build：$DEST 已存在且不是软链，拒绝覆盖" >&2
    exit 1
  else
    ln -s "$ENTRY" "$DEST"
  fi
  echo "fitcoach build：$DEST → $ENTRY" >&2
fi
