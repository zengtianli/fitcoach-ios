#!/usr/bin/env python3
"""Make an opaque Store-sized copy only from this run's actual quiet Mac capture."""
import hashlib
import json
import os
from pathlib import Path
import sys

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import store_shots


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    detail = Path(os.environ['SOP_OUT_DIR']) / 'launch_mac.detail.json'
    data = json.loads(detail.read_text())
    if data.get('platform') != 'mac' or data.get('passed') is not True:
        raise ValueError('Only a passed Mac launch from this invocation can produce a Store shot')
    source = (ROOT / data['screenshot']).resolve(strict=True)
    source.relative_to(ROOT)
    if sha(source) != data['screenshot_sha256']:
        raise ValueError('Quiet screenshot changed')
    target = ROOT / 'shots/appstore/mac/01-schedule.png'
    target.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as original:
        # cacheDisplay cannot read the AppKit sidebar material. Preserve the original
        # and select its genuine schedule/balance region, without reconstructing UI.
        if original.size != (2360, 1560):
            raise ValueError('Mac viewport changed; review crop against the new actual capture')
        crop = (420, 0, 2360, 1560)
        shot = ImageOps.contain(original.convert('RGB').crop(crop), (2560, 1600), Image.Resampling.LANCZOS)
        canvas = Image.new('RGB', (2560, 1600), '#f4f6f8')
        canvas.paste(shot, ((2560 - shot.width) // 2, (1600 - shot.height) // 2))
        canvas.save(target)
    issues = store_shots.validate('mac', [target])
    if issues:
        raise ValueError('; '.join(issues))
    proof = {'schema_version': 1, 'environment': 'native macOS, in-process offscreen capture',
             'source': str(source.relative_to(ROOT)), 'source_sha256': sha(source),
             'launch_detail': str(detail.relative_to(ROOT)), 'launch_detail_sha256': sha(detail),
             'build': data.get('build'), 'output': str(target.relative_to(ROOT)), 'output_sha256': sha(target),
             'crop_pixels': list(crop),
             'transformation': 'actual schedule/balance content cropped from original; opaque RGB padded to 2560x1600; no reconstructed UI',
             'scope': 'isolated demo backend; no production account; no App Store upload'}
    (ROOT / 'perf/media/mac-store-shot.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')
    print('Mac actual quiet screenshot copied to Store dimensions; shared specification passed')


if __name__ == '__main__':
    main()
