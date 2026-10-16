#!/usr/bin/env python3
"""Build-only candidate through the existing shared sim_lane, never install the Mac app."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('mac', 'iphone'), required=True)
    parser.add_argument('--work-dir', type=Path, help='existing shared lane DerivedData, outside this repository')
    args = parser.parse_args()
    target = ROOT / 'build/accept' / (args.platform + '-build-receipt.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    previous = json.loads(target.read_text()) if target.is_file() else {}
    work = args.work_dir or (Path(previous['work_dir']) if previous.get('work_dir') else None)
    result = sim_lane.build(ROOT, 'FitCoach', args.platform, work_dir=work)
    # Xcode Debug can put all Swift code in *.debug.dylib while the main executable is a stable stub.
    # Bind the entire real bundle, not just that stub's SHA from the generic lane receipt.
    app = Path(result['app_path'])
    result['product_artifacts'] = {str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sorted(app.rglob('*')) if path.is_file()}
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'receipt': str(target), 'app': result['app_path'], 'seconds': result['seconds']}, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    try:
        main()
    except sim_lane.Busy as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(75)
