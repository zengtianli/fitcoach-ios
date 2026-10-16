#!/usr/bin/env python3
"""Reuse the existing genuine growth-chart operation clip, preserving its historical scope."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    archive = ROOT.parent / '02-审核/历史版本/1.0-build1/02-视频'
    source = archive / 'clips/core-segment-06.mp4'
    original = archive / '原片/take2c-20260909/part-003.mov'
    edit = archive / 'core-demo-edit-list.json'
    if json.loads(edit.read_text())[-1][1:] != [3, 40, 19, '两次体测与成长趋势']:
        raise ValueError('Historical edit list changed; review the actual operation before reuse')
    # Decode the whole actual clip; this is not the portal screenshot montage.
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(source), '-f', 'null', '-'], check=True)
    target = ROOT / 'shots/media/growth-operation-20260909.mp4'
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.is_file() or sha(target) != sha(source):
        shutil.copyfile(source, target)
    proof = {'schema_version': 1, 'kind': 'reuse-existing-operation-recording',
             'recorded_at': '2026-09-09', 'reviewed_at': '2026-10-16',
             'source': str(source), 'source_sha256': sha(source),
             'continuous_original': str(original), 'continuous_original_sha256': sha(original),
             'edit_list': str(edit), 'edit_list_sha256': sha(edit),
             'source_interval_seconds': [40, 59], 'duration_seconds': 19,
             'output': str(target.relative_to(ROOT)), 'output_sha256': sha(target),
             'observed': 'real tap from student record to two-measurement growth chart; reviewed video frames',
             'scope': 'historical business demonstration only; does not cover current account/settings, current build or performance',
             'transform': 'byte copy; no fabricated frames, pointer events or new recording claim'}
    (ROOT / 'perf/media/business-clip-reuse.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'video': str(target.relative_to(ROOT)), 'sha256': sha(target), 'duration_seconds': 19}))


if __name__ == '__main__':
    main()
