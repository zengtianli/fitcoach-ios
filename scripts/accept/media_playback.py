#!/usr/bin/env python3
"""Expand the registered complete media globs, then use Chapter's original player/decoder."""
import json
import importlib.util
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
ENGINE = Path.home() / 'Apps/chapter/engine'
sys.path.insert(0, str(ENGINE))
import app_sop

# The original proxy buffers upstream responses with a 30s network timeout.
# Its default 20s player budget can expire before a valid video GET finishes.
# Allow that transfer and actual playback to finish; keep the original decoder,
# browser, pass/fail criteria and environment-deferred handling unchanged.
PAGE_WAIT_MS = 60000


def main():
    config = json.loads(os.environ['SOP_CONFIG'])
    files = app_sop.media_files({'repo': ROOT, 'sop': config})
    config['media'] = [str(path.relative_to(ROOT)) for path in files]
    if not any(path.suffix.lower() in ('.mp4', '.mov', '.webm', '.m4v') for path in files):
        raise SystemExit('No actual local operation video found; refusing to silently reduce coverage')
    os.environ['SOP_CONFIG'] = json.dumps(config, ensure_ascii=False)
    sys.path.insert(0, str(ENGINE / 'acceptors'))
    spec = importlib.util.spec_from_file_location('fitcoach_shared_media', ENGINE / 'acceptors/media_playback.py')
    player = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(player)
    original_load_page = player.load_page

    def load_page(*args, **kwargs):
        return original_load_page(*args, **{**kwargs, 'wait_ms': PAGE_WAIT_MS})

    player.load_page = load_page
    return player.main([])


if __name__ == '__main__':
    raise SystemExit(main())
