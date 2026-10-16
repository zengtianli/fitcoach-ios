#!/usr/bin/env python3
"""Account acceptance: real current client/service regression, with explicit native/SMS gaps.

The local fake transport must never be promoted to real SMS or native page coverage.
Run through Chapter, which serializes the existing CLI build and writes delivery evidence.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from test_runtime import backend_python


def main():
    out = Path(os.environ['SOP_OUT_DIR']).resolve()
    raw = ROOT / 'perf/account/raw' / ('accept-' + uuid.uuid4().hex)
    raw.mkdir(parents=True)
    service = Path(os.environ.get('FITCOACH_TEST_BACKEND') or ROOT.parents[1] / 'service').resolve()
    runtime = backend_python(service)
    # Original build entry; no installed binary, production preference or account changes.
    subprocess.run(['bash', 'cli/build.sh'], cwd=ROOT, check=True)
    cli = ROOT / 'build/cli/fitcoach'
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'FITCOACH_TEST_BACKEND': str(service),
           'FITCOACH_ACCOUNT_RAW': str(raw), 'FITCOACH_ACCOUNT_CLI': str(cli)}
    run = subprocess.run([str(runtime), 'scripts/accept/account_lifecycle/fixture.py'],
                         cwd=ROOT, env=env, capture_output=True, text=True)
    proof = raw / 'client-service.json'
    report = json.loads(proof.read_text()) if proof.is_file() else {}
    # Do not persist a traceback whose locals could contain one-time tokens or passwords.
    detail = {
        'schema_version': 1,
        'client_environment': 'current source CLI, native App account pages not yet exercised',
        'service_environment': 'localhost FastAPI production routes, disposable tenant DB, existing fake SMS fixture',
        'sms_transport': 'fake', 'real_sms_sent': 0,
        'local_client_regression': {'passed': run.returncode == 0 and report.get('ok') is True,
                                    'exit_code': run.returncode,
                                    'assertions': report.get('assertion_count', 0)},
        'account_cases': {name: {'status': 'unverified',
            'reason': 'Native page flow and real authorized SMS delivery/verification are required'} for name in (
            'registration', 'login', 'password_change', 'password_recovery', 'logout', 'account_deletion',
            'abuse_protection', 'data_preservation', 'phone_verification', 'phone_binding', 'phone_change',
            'sms_delivery', 'phone_login')},
        'remaining': ['No explicitly authorized test recipient in this task',
                      'No fixed in-process native account-page driver yet; CLI does not prove native page actions'],
    }
    if proof.is_file():
        detail['local_client_regression'].update(evidence=str(proof.relative_to(ROOT)),
                                                evidence_sha256=hashlib.sha256(proof.read_bytes()).hexdigest())
    out.mkdir(parents=True, exist_ok=True)
    (out / 'account_lifecycle.detail.json').write_text(json.dumps(detail, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(detail['local_client_regression'], ensure_ascii=False))
    print('FAIL: local regression is not native account lifecycle; real SMS recipient and native page driver remain unverified')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
