#!/usr/bin/env python3
"""Expand the registered complete media globs, then use Chapter's original player/decoder."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ENGINE = Path.home() / 'Apps/chapter/engine'
sys.path.insert(0, str(ENGINE))
import app_sop

config = json.loads(os.environ['SOP_CONFIG'])
files = app_sop.media_files({'repo': ROOT, 'sop': config})
config['media'] = [str(path.relative_to(ROOT)) for path in files]
if not any(path.suffix.lower() in ('.mp4', '.mov', '.webm', '.m4v') for path in files):
    raise SystemExit('No actual local operation video found; refusing to silently reduce coverage')
env = {**os.environ, 'SOP_CONFIG': json.dumps(config, ensure_ascii=False)}
raise SystemExit(subprocess.run([sys.executable, str(ENGINE / 'acceptors/media_playback.py')], cwd=ROOT, env=env).returncode)
