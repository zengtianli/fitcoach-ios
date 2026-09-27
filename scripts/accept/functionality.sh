#!/bin/bash
# Actual production Swift API/model contract against a disposable local backend.
# No simulator, device, installed app, real account or UI input is involved.
set -euo pipefail
source "$(dirname "$0")/_common"

functionality_accept() {
  # Keep the existing contract assertions as the single source of truth. Only
  # adapt its top-level entry to the shared compiler's @main convention.
  python3 - "$ACCEPT_TMP/FunctionalityMain.swift" <<'PY'
from pathlib import Path
import sys

source = Path("ref/main.swift").read_text()
entry = "\nawait runContract()\n"
if source.count(entry) != 1 or not source.endswith(entry):
    raise SystemExit("FAIL: ref/main.swift entry changed; update the acceptance adapter")
source = source[:-len(entry)] + """
@main
struct FunctionalityAcceptance {
    static func main() async {
        await runContract()
    }
}
"""
Path(sys.argv[1]).write_text(source)
PY
  accept_compile "$ACCEPT_TMP/FunctionalityMain.swift"
  accept_start_backend

  # The base URL is assigned only by accept_start_backend after readiness. Its
  # server owns its socket before publication; caller FC_* values were cleared.
  export FC_EMAIL='accept-functionality@example.invalid'
  export FC_PASS='Acceptance-only-234!'
  curl --noproxy '*' --fail --silent --show-error \
    --request POST "$FC_BASE/api/register" \
    --data-urlencode "email=$FC_EMAIL" \
    --data-urlencode "password=$FC_PASS" \
    --data-urlencode 'display_name=Acceptance' --output /dev/null

  # The compiler gives this process a unique defaults domain. This home also
  # confines CoreFoundation preferences to disposable test state.
  mkdir -p "$ACCEPT_TMP/preferences"
  CFFIXED_USER_HOME="$ACCEPT_TMP/preferences" "$ACCEPT_BIN"
}

# Chapter captures this output verbatim. Retain diagnostics while keeping local
# home and scratch paths out of public acceptance evidence, including failures.
# Run in this shell (not a pipeline subshell), so cleanup owns every server PID.
functionality_report() {
  local status=$?
  if [ -f "$ACCEPT_TMP/result.log" ]; then
    sed -e "s|$ACCEPT_TMP|<scratch>|g" -e "s|$HOME|~|g" "$ACCEPT_TMP/result.log"
  fi
  accept_cleanup
  exit "$status"
}
trap functionality_report EXIT
functionality_accept >"$ACCEPT_TMP/result.log" 2>&1
