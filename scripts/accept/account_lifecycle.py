#!/usr/bin/env python3
"""Account acceptance: actual native pages and current CLI against disposable real routes.

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
from product_basics import current_build, owner_snapshot
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane


def main():
    owner_before = owner_snapshot()
    out = Path(os.environ['SOP_OUT_DIR']).resolve()
    raw = ROOT / 'perf/account/raw' / ('accept-' + uuid.uuid4().hex)
    raw.mkdir(parents=True)
    service = Path(os.environ.get('FITCOACH_TEST_BACKEND') or ROOT.parents[1] / 'service').resolve()
    runtime = backend_python(service)
    # Original build entry; no installed binary, production preference or account changes.
    try:
        # Only the custom CLI compilation uses this slot; native builds own theirs.
        with sim_lane.BuildSlot('fitcoach-ios:account-cli', wait=0):
            subprocess.run(['bash', 'cli/build.sh'], cwd=ROOT, check=True)
    except sim_lane.Busy as exc:
        print('CLI candidate build deferred: ' + str(exc))
        return 75
    cli = ROOT / 'build/cli/fitcoach'
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'FITCOACH_TEST_BACKEND': str(service),
           'FITCOACH_ACCOUNT_RAW': str(raw), 'FITCOACH_ACCOUNT_CLI': str(cli)}
    run = subprocess.run([str(runtime), 'scripts/accept/account_lifecycle/fixture.py'],
                         cwd=ROOT, env=env, capture_output=True, text=True)
    proof = raw / 'client-service.json'
    report = json.loads(proof.read_text()) if proof.is_file() else {}
    native = {}
    for platform in ('mac', 'iphone'):
        receipt = ROOT / f'build/accept/{platform}-build-receipt.json'
        try:
            current_build(platform, receipt, prepare=True)
        except (sim_lane.Busy, sim_lane.LaneError, RuntimeError) as exc:
            native[platform] = {'passed': False, 'exit_code': 75 if isinstance(exc, sim_lane.Busy) else 1,
                                'checks': {}, 'error': str(exc)}
            break
        target = raw / platform
        result = subprocess.run([str(runtime), 'scripts/accept/account_lifecycle/native_fixture.py',
            '--platform', platform, '--receipt', str(receipt), '--out', str(target)], cwd=ROOT, env=env)
        artifact = target / 'native.json'
        parsed = json.loads(artifact.read_text()) if artifact.is_file() else {}
        native[platform] = {'passed': result.returncode == 0 and bool(parsed.get('checks')) and all(parsed['checks'].values()),
                            'exit_code': result.returncode, 'checks': parsed.get('checks', {}), 'error': parsed.get('error')}
        if artifact.is_file():
            native[platform].update(evidence=str(artifact.relative_to(ROOT)), evidence_sha256=hashlib.sha256(artifact.read_bytes()).hexdigest())
        if result.returncode:
            break
    owner_after = owner_snapshot()
    local_passed = (run.returncode == 0 and report.get('ok') is True and owner_before == owner_after
                    and len(native) == 2 and all(item['passed'] for item in native.values()))
    # Do not persist a traceback whose locals could contain one-time tokens or passwords.
    detail = {
        'schema_version': 1,
        'client_environment': 'current-source Mac offscreen and iPhone headless simulator; mounted SwiftUI account pages and actual button actions; current CLI',
        'service_environment': 'localhost FastAPI production routes, disposable tenant DB, existing fake SMS fixture',
        'sms_transport': 'fake', 'real_sms_sent': 0,
        'local_client_regression': {'passed': run.returncode == 0 and report.get('ok') is True,
                                    'exit_code': run.returncode,
                                    'assertions': report.get('assertion_count', 0)},
        'native_client_regression': native,
        'owner_before': owner_before, 'owner_after': owner_after,
        'production_data_preserved': owner_before == owner_after,
        'account_cases': {name: {'status': 'passed' if local_passed else 'unverified',
            'scope': 'isolated native client and disposable real service routes; fake SMS transport',
            **({'evidence': native['iphone']['evidence'], 'evidence_sha256': native['iphone']['evidence_sha256']} if local_passed else {})} for name in (
            'registration', 'login', 'password_change', 'password_recovery', 'logout', 'account_deletion',
            'abuse_protection', 'data_preservation', 'phone_verification', 'phone_binding', 'phone_change',
            'sms_delivery', 'phone_login')},
        'remaining': (['Real authorized SMS recipient and delivery/verification remain pending'] if local_passed else
                      ['Native or CLI isolated regression has not completed', 'Real authorized SMS recipient remains pending']),
    }
    detail['account_cases']['sms_delivery'] = {'status': 'unverified', 'reason': 'Waiting for the owner-provided dedicated recipient; zero real messages sent'}
    if proof.is_file():
        detail['local_client_regression'].update(evidence=str(proof.relative_to(ROOT)),
                                                evidence_sha256=hashlib.sha256(proof.read_bytes()).hexdigest())
    out.mkdir(parents=True, exist_ok=True)
    (raw / 'account.json').write_text(json.dumps(detail, ensure_ascii=False, indent=2) + '\n')
    (out / 'account_lifecycle.detail.json').write_text(json.dumps(detail, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(detail['local_client_regression'], ensure_ascii=False))
    print('FAIL: ' + ('Only real authorized SMS delivery remains unverified' if local_passed else 'Native/CLI isolated account regression incomplete; inspect per-platform raw checks'))
    return 75 if any(item['exit_code'] == 75 for item in native.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
