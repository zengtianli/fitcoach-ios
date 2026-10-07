#!/bin/bash
# fitcoach config / update / app 的隔离测试：把 Mac 版 App 的源码直接编成一个可执行文件（不签名、不进沙盒、不装机），
# 放进 build/agentcli/ 下一个只有 Info.plist 的 .app 壳，再让 build/cli/fitcoach 转调它。
# 壳的 bundle id 是专用测试域 cyou.tianli.fitcoachapp.relaytest：没进沙盒的进程用正式 bundle id 会写到本人真实偏好域。
# 不开窗口、不碰本人真实偏好、iCloud、钥匙串与已装的 App（见 cli/test_app_relay.py 文件头）。
#   bash cli/test_app_relay.sh            编 + 测
#   bash cli/test_app_relay.sh --no-build 只测（沿用上次编出的）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/agentcli/上门体育.app"
if [ "${1:-}" != "--no-build" ]; then
  # shellcheck disable=SC1090
  source "$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh" && xcode_env_use macosx
  bash cli/build.sh
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cyou.tianli.fitcoachapp.relaytest</string>
<key>CFBundleExecutable</key><string>FitCoach</string>
<key>CFBundleName</key><string>上门体育</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  # 与 project.yml 里 FitCoach 目标的 macOS 源码清单一致：Shared 八份 + Sources 全部；APP_LIFECYCLE_KVS 同 Mac 构建。
  xcrun swiftc -Onone -swift-version 5 -parse-as-library -D APP_LIFECYCLE_KVS -module-name FitCoach \
    -target "$(uname -m)-apple-macos15.0" -suppress-warnings \
    Shared/PlatformCompat.swift Shared/LaneSignal.swift Shared/AppLifecycle.swift Shared/AppConfiguration.swift \
    Shared/AppLifecycleMobile.swift Shared/AppLifecycleUI.swift Shared/AppLifecycleCLI.swift Shared/RemoteUI.swift \
    Sources/*.swift -o "$APP/Contents/MacOS/FitCoach"
fi
[ -x "$APP/Contents/MacOS/FitCoach" ] || { echo "FAIL: 没有 $APP/Contents/MacOS/FitCoach（去掉 --no-build 先编）" >&2; exit 1; }
python3 cli/test_app_relay.py "$APP"
