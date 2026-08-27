#!/bin/bash
# 把 app 装到真 iPhone。前提:已在 Xcode 里登录 Apple ID(GUI,只需一次)。
#
# 注意:免费账号的 Apple Development 证书**不是登录时生成的**,是第一次为真机构建
# (xcodebuild -allowProvisioningUpdates)时由 Xcode 现场申请的。所以本脚本不预先
# 检查证书存在与否 —— 那道门会把正常的首次流程挡在外面。
#
# 免费 Personal Team 的两个硬限制(与本脚本无关):
#   · 证书 7 天到期 —— 到期后 app 打不开,重跑本脚本即可续
#   · 同时最多 3 个自签 app
set -uo pipefail
cd "$(dirname "$0")"
# ── 项目身份:一律从 project.yml 派生,禁在本脚本里写死 ───────────────────────
# 为什么(2026-08-19 立):/appios 教的起新 app 方式就是 `cp -R options-calc <name>`。
# 名字写死在这里 = 每复制一次就留三处待改(工程名/scheme/产物名/bundle id),
# 漏一处的表现是「编的是新 app、装上去的是旧 app」——**它不会报错**。
# 上一轮同一个 cp -R 已经在「写死 Xcode 路径」上踩过一次,同一种病不修第二遍。
PROJ=$(sed -n 's/^name: *//p' project.yml | head -1)
BUNDLE=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: *//p' project.yml | head -1)
[ -n "$PROJ" ]   || { echo "❌ project.yml 里读不出 name:" >&2; exit 1; }
[ -n "$BUNDLE" ] || { echo "❌ project.yml 里读不出 PRODUCT_BUNDLE_IDENTIFIER:" >&2; exit 1; }
die() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

# ── [1] 挑 Xcode:走总部 SSOT,禁写死路径(铁律 #5)────────────────────────────
#    SSOT: /Users/tianli/Dev/tools/dev/lib/tools/macapp/xcode_env.{py,sh}
# (2026-08-18 实证:手机 iOS 27.0 + Xcode 26.6 → devicectl 报 `connected (no DDI)`,
#  装不上;换 Xcode 27 beta 后同一台设备立刻变成干净的 `connected`。)
#
# 这里**挑两次**,不是啰嗦:
#   第一次没有 min-sdk —— 因为「设备系统版本」要靠 `xcrun devicectl` 才问得到,
#   而 xcrun 本身就需要一个已选定的 DEVELOPER_DIR。先拿一个能跑的工具链。
#   第二次带 $DEVOS —— 设备版本到手后再按「iOS SDK 不低于设备系统」重挑一遍。
#   原先那 20 行自写挑选只做了「取 SDK 最高的那个」,**从不校验它 ≥ 设备系统**,
#   所以 no DDI 那个坑它其实拦不住,是人换的 Xcode。
_XCODE_ENV_SH=/Users/tianli/Dev/tools/dev/lib/tools/macapp/xcode_env.sh
[ -f "$_XCODE_ENV_SH" ] || die "缺总部 Xcode SSOT $_XCODE_ENV_SH(禁写死 Xcode 路径顶上)"
# shellcheck source=/dev/null
source "$_XCODE_ENV_SH"
echo "[1/6] 挑 Xcode"
xcode_env_use ios
echo "      ✅ 用 $XCODE_ENV_NAME  (iOS SDK $XCODE_ENV_SDK)"

# ── [2] 找真机 ────────────────────────────────────────────────────────────────
echo "[2/6] 找连着的 iPhone"
J=$(mktemp)
xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1 || true
read -r UDID DEVNAME DEVOS <<<"$(python3 detect_device.py "$J" 2>/dev/null)"
if [ -z "${UDID:-}" ]; then
  echo "      devicectl 当前看到:"; xcrun devicectl list devices 2>/dev/null | sed 's/^/        /'
  die "没有处于 connected 的 iPhone。逐条确认:
   ① 数据线插上(首次别用 WiFi)
   ② iPhone 解锁,弹「信任此电脑」点信任并输密码
   ③ 设置 → 隐私与安全性 → 拉到底 → 开发者模式 → 打开(要重启手机)
   ④ 若状态是「connected (no DDI)」:手机系统比 Xcode 新,装对应版本的 Xcode"
fi
echo "      ✅ ${DEVNAME//_/ }  iOS $DEVOS  ($UDID)"

# 设备系统版本到手 → 按它重挑一次 Xcode。**这一步才是真正拦 no DDI 的那道门**:
# 上面第一次挑只保证「有 iOS SDK」,这次要求「iOS SDK 不低于 $DEVOS」,挑不出就硬失败,
# 而不是编到一半在 devicectl 那里报一句完全不提「换 Xcode」的 `connected (no DDI)`。
xcode_env_use ios "$DEVOS"
echo "      ✅ 按设备 iOS $DEVOS 重挑: $XCODE_ENV_NAME (iOS SDK $XCODE_ENV_SDK)"

# ── [3] 取 Team ID ────────────────────────────────────────────────────────────
# 首次为真机构建前**还没有证书**,所以不能从证书里读 team。Xcode 登录后会把
# team 写进自己的偏好(IDEProvisioningTeamByIdentifier),从那里读才对。
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "[3/6] 取 Team ID"
  DEVELOPMENT_TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -n 's/.*teamID *= *\([A-Z0-9]*\).*/\1/p' | head -1)
  [ -n "$DEVELOPMENT_TEAM" ] || die "读不出 Team ID。
   → 确认 Xcode → Settings → Apple Accounts 里已登录且能看到你的账号。
   → 或手动指定: DEVELOPMENT_TEAM=<你的TeamID> bash $0"
  TEAMNAME=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -n 's/.*teamName *= *"\(.*\)".*/\1/p' | head -1)
  echo "      ✅ $DEVELOPMENT_TEAM  ${TEAMNAME:-}"
fi

# ── [4] 编 + 让 Xcode 现场申请证书与 profile ──────────────────────────────────
echo "[4/6] 编译 + 申请签名(首次会慢,证书就是这一步生成的)"
LOG=$(mktemp)
xcodebuild -project "$PROJ.xcodeproj" -scheme "$PROJ" \
  -destination "id=$UDID" -derivedDataPath .dd-device \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} \
  build >"$LOG" 2>&1
if [ $? -ne 0 ]; then
  grep -E 'error:|Provisioning|requires a development team|Signing' "$LOG" | head -12 | sed 's/^/      /'
  die "编译/签名失败,完整日志: $LOG
   常见原因:
   · 「requires a development team」→ 有多个 team 分不清,用 DEVELOPMENT_TEAM=<ID> 重跑;
     查 ID: security find-identity -v -p codesigning
   · 「Unable to log in with account」→ Xcode → Settings → Apple Accounts 重登一次
   · 「maximum number of apps for free development profiles」→ 免费账号同时最多 3 个自签 app,
     去手机上删掉一个别的自签 app"
fi
echo "      ✅ BUILD SUCCEEDED"
APP=$(find .dd-device -name "$PROJ.app" -path '*iphoneos*' 2>/dev/null | head -1)
[ -n "$APP" ] || die "编出来了但找不到 .app,日志: $LOG"

# ── [4] 装 ────────────────────────────────────────────────────────────────────
echo "[5/6] 安装到手机"
xcrun devicectl device install app --device "$UDID" "$APP" >"$LOG.ins" 2>&1 \
  || { tail -10 "$LOG.ins" | sed 's/^/      /'; die "安装失败,日志: $LOG.ins"; }
echo "      ✅ 已安装"

# ── [5] 启动 ──────────────────────────────────────────────────────────────────
echo "[6/6] 启动"
if xcrun devicectl device process launch --device "$UDID" "$BUNDLE" >"$LOG.run" 2>&1; then
  echo "      ✅ 已启动"
else
  echo "      ⚠ 自动启动没成功(不影响安装)。多半是还没信任开发者证书:"
  echo "        iPhone → 设置 → 通用 → VPN 与设备管理 → 开发者应用 → 信任"
fi

DISPLAY_NAME=$(sed -n 's/.*INFOPLIST_KEY_CFBundleDisplayName: *//p' project.yml | head -1)
DISPLAY_NAME=${DISPLAY_NAME:-$PROJ}
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 手机主屏找「${DISPLAY_NAME}」。

⚠ 首次打开若提示「不受信任的开发者」:
   设置 → 通用 → VPN 与设备管理 → 开发者应用 → 你的 Apple ID → 信任

⏳ 免费证书 7 天到期,到时 app 打不开。续期 = 重跑本脚本:
   bash $(pwd)/install-to-iphone.sh
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
