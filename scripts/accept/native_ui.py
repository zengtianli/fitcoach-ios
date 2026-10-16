#!/usr/bin/env python3
"""Serial candidate preparation + the actual in-process Mac/iPhone settings UI suite.

The original product_basics entry still defaults to the installed Mac app. This
explicit candidate entry builds through the shared lane and never installs it.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane
sys.path.insert(0, str(Path.home() / 'Apps/chapter/engine'))
import app_sop
import product_basics


def main():
    out = Path(os.environ['SOP_OUT_DIR'])
    receipts = {}
    for platform, previous_lane in [('mac', 'mac'), ('iphone', 'ipad')]:
        receipt = ROOT / f'build/accept/{platform}-build-receipt.json'
        try:
            built = sim_lane.reuse_build(receipt, 'fitcoach-ios', ROOT, platform, scheme='FitCoach')
            assert built.get('product_artifacts'), 'Full candidate bundle hash required'
        except (sim_lane.LaneError, AssertionError):
            cmd = [sys.executable, 'scripts/build_product_basics.py', '--platform', platform]
            # An actual recent launch provides warm DerivedData only; the original
            # build runs again and emits its own full receipt. Never reconstruct one.
            old = out / f'launch_{previous_lane}.detail.json'
            if old.is_file():
                launch = json.loads(old.read_text())
                log = (launch.get('build') or {}).get('log')
                if launch.get('passed') is True and log and Path(log).is_file():
                    cmd += ['--work-dir', str(Path(log).parent)]
            subprocess.run(cmd, cwd=ROOT, check=True)
        receipts[platform] = json.loads(receipt.read_text())
    env = {**os.environ, 'SOP_PRODUCT_BASICS_SPEC': json.dumps(product_basics.spec(app_sop.load_apps('fitcoach-ios')[0]))}
    run = subprocess.run([sys.executable, 'scripts/accept/product_basics.py',
        '--app', receipts['mac']['app_path'], '--receipt', str(ROOT / 'build/accept/mac-build-receipt.json'),
        '--ios-receipt', str(ROOT / 'build/accept/iphone-build-receipt.json')], cwd=ROOT, env=env)
    detail = json.loads((out / 'product_basics.detail.json').read_text())
    (out / 'native_ui.detail.json').write_text(json.dumps({**detail,
        'passed': run.returncode == 0, 'artifact_scope': 'current-source candidate, not installed',
        'method': 'actual product --ui-self-test; offscreen Mac views and headless iPhone simulator; direct model actions'},
        ensure_ascii=False, indent=2) + '\n')
    return run.returncode


if __name__ == '__main__':
    raise SystemExit(main())
