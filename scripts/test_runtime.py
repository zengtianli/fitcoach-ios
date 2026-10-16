#!/usr/bin/env python3
"""Locate an existing test runtime without modifying the sibling service environment."""
import os
from pathlib import Path
import subprocess


def backend_python(service: Path) -> Path:
    explicit = os.environ.get('FITCOACH_TEST_PYTHON')
    candidates = [Path(explicit)] if explicit else [service / '.venv/bin/python', Path.home() / 'Dev/.venv/bin/python']
    failures = []
    for path in candidates:
        if not path.is_file() or not os.access(path, os.X_OK):
            failures.append(str(path) + ': missing')
            continue
        result = subprocess.run([str(path), '-c', 'import fastapi,uvicorn,jinja2,multipart'],
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}, capture_output=True, timeout=15)
        if result.returncode == 0:
            return path
        failures.append(str(path) + ': backend dependencies unavailable')
    raise RuntimeError('No local test Python; set FITCOACH_TEST_PYTHON. ' + '; '.join(failures))


if __name__ == '__main__':
    import sys
    service = Path(os.environ.get('FITCOACH_TEST_BACKEND') or Path(__file__).resolve().parents[3] / 'service')
    try:
        print(backend_python(service))
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(78)
