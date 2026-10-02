#!/bin/bash
# Apple Watch 与 Vision Pro 的便宜编译车道：不起模拟器、不建工程、不出产物。
# 按 project.yml 里各 target 的 `sources:`（与生成工程同一份清单）对 watchsimulator / xrsimulator SDK 做 swiftc 类型检查：
# 给某个 target 加了一个在那个平台上编不过的文件，在这里就红，而不是第一次红在 Xcode Cloud 上。
# 照成长小金库 Tests/check-platform-typecheck.sh（2026-10-02）。
#   bash Tests/check-platform-typecheck.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# project.yml 里一个 target 的 Swift 源文件：它的 `- path:` 条目（文件，或目录下的 *.swift）。
sources() {
  python3 - "$1" <<'PY'
import re, sys
from pathlib import Path
target, lines = sys.argv[1], Path("project.yml").read_text(encoding="utf-8").splitlines()
inside = in_sources = False
out = []
for line in lines:
    if re.match(r"^  \S.*:\s*$", line):                    # target 键（两格缩进）
        inside = line.strip() == f"{target}:"
        in_sources = False
        continue
    if not inside:
        continue
    if re.match(r"^    \S", line):                          # target 的属性
        in_sources = line.strip() == "sources:"
        continue
    m = re.match(r"^\s+- path: (.+?)\s*$", line)
    if in_sources and m:
        p = Path(m.group(1).strip('"'))
        if p.suffix == ".swift":
            out.append(str(p))
        elif p.is_dir():
            out += sorted(str(f) for f in p.glob("*.swift"))
if not out:
    sys.exit(f"project.yml 里找不到 target {target} 的 Swift 源文件")
print("\n".join(out))
PY
}

XENV="$HOME/Dev/tools/dev/lib/tools/macapp/xcode_env.sh"
check() {
  local label="$1" sdk="$2" triple="$3"; shift 3
  local files=("$@")
  ( if [ -f "$XENV" ]; then source "$XENV"; xcode_env_use "$sdk" >/dev/null; fi
    xcrun --sdk "$sdk" swiftc -typecheck -parse-as-library -swift-version 5 -target "$triple" "${files[@]}" )
  echo "  ✅ $label: ${#files[@]} 个文件类型检查通过（$sdk, $triple）"
}

watch_app=(); while IFS= read -r f; do watch_app+=("$f"); done < <(sources FitCoachWatch)
watch_widget=(); while IFS= read -r f; do watch_widget+=("$f"); done < <(sources FitCoachWatchWidget)
check "手表 app" watchsimulator arm64-apple-watchos11.0-simulator "${watch_app[@]}"
check "表盘复杂功能" watchsimulator arm64-apple-watchos11.0-simulator "${watch_widget[@]}"

# Vision Pro 跑的是与 iPhone / iPad / Mac 同一个 FitCoach target：Shared + Sources/ 全部
vision_app=(); while IFS= read -r f; do vision_app+=("$f"); done < <(sources FitCoach)
check "Vision Pro app" xrsimulator arm64-apple-xros26.0-simulator "${vision_app[@]}"
echo "PASS: watchOS 与 visionOS 源码类型检查通过"
