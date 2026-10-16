#!/usr/bin/env python3
"""Build-only preparation for the original queued sampler, using its existing SDK cache.

No simulator boot, sampling, installation or evidence rewriting. sim_lane.build
owns the shared build slots. The resulting manifest is consumed by Chapter's
--reuse-builds-manifest / --reuse-builds-manifest-sha256, with original validation.
"""
import contextlib
import hashlib
import json
from pathlib import Path
import sys

from measure_platforms import APP_ID, LANES, REPO, shared_tools


def main():
    shared = shared_tools()
    manifest = {'schema_version': 1, 'app_id': APP_ID, 'platforms': {}}
    with contextlib.ExitStack() as leases:
        for lane in LANES:
            cfg = shared.lane_config(REPO, lane)
            if cfg.get('not_applicable') or cfg.get('component'):
                continue
            built = shared.cached_build(APP_ID, REPO, lane, cfg.get('scheme') or shared.default_scheme(REPO, lane), False, leases)
            receipt = Path(built['work_dir']) / 'build.json'
            assert receipt.is_file()
            manifest['platforms'][lane] = {'size_receipt': str(receipt), 'runtime_receipt': str(receipt)}
            # Persist each completed SDK so interrupted preparation is resumable.
            target = REPO / 'build/perf/current-builds.json'
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'manifest': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try: raise SystemExit(main())
    except shared_tools().sim_lane.Busy as exc:
        print(str(exc), file=sys.stderr); raise SystemExit(75)
