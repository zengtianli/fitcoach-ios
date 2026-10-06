"""Original sim_lane Session and strict unsigned SDK receipt, actual disposable account endpoint.
No UI input, no SDK rebuild, no cloud send. Captures only the existing phone-account deep screen.
The fixture synthetic cookie is redacted by the original lane; SavedLogin is not exercised.
"""
import hashlib
import json
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest
import uvicorn

SERVICE = Path('/Users/tianli/Apps/fitcoach/service')
REPO = Path('/Users/tianli/Apps/fitcoach/ios/01-源程序')
RAW = REPO / 'perf/account/raw/sms-native-delivery-20261006'
APP = Path('/private/tmp/sms-apps-20261006/fitcoach-iphone-final/dd/Build/Products/Debug-iphonesimulator/FitCoach.app')
UDID = 'C77A68B8-7EB3-46B8-9963-838439E95E86'
sys.path.insert(0, '/Users/tianli/Dev/tools/dev/lib/tools/macapp/ios')
# Shared lane's Chapter receipt resolver needs its existing PyYAML; product venv lacks it.
sys.path.append('/Users/tianli/Dev/.venv/lib/python3.12/site-packages')
import sim_lane
sys.path.insert(0, str(SERVICE / 'tests'))
import test_phone as fixture

sim_lane.reuse_build('/private/tmp/sms-apps-20261006/fitcoach-iphone-final.json',
                     'fitcoach-ios', REPO, 'iphone', 'FitCoach', 'Debug', False)
derivation = json.loads((RAW / 'signed-simulator-derivation.json').read_text())
assert hashlib.sha256((APP / 'FitCoach').read_bytes()).hexdigest() == derivation['base_executable_sha256']
info = sim_lane.bundle_info(APP)
report = {'ok': False, 'kind': 'unsigned_simulator_phone_form_capture',
          'app': str(APP), 'base_executable_sha256': derivation['base_executable_sha256'],
          'base_receipt': derivation['base_receipt'], 'rebuilt': False,
          'signing': 'original successful unsigned SDK package', 'real_sms_sent': 0,
          'keychain_consumer_verified': False, 'production_account_pass': False,
          'ui_input_performed': False, 'environment': 'simulator', 'screens': []}

with tempfile.TemporaryDirectory(prefix='fitcoach-signed-native-fixture-') as scratch:
    mp = pytest.MonkeyPatch()
    gen = fixture.lane.__wrapped__(Path(scratch), mp)
    lane = next(gen)
    sock = socket.socket(); sock.bind(('127.0.0.1', 0))
    base = f'http://127.0.0.1:{sock.getsockname()[1]}'
    server = uvicorn.Server(uvicorn.Config(fixture.api.app, log_level='error', access_log=False))
    thread = threading.Thread(target=server.run, kwargs={'sockets': [sock]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while not server.started and time.monotonic() < deadline: time.sleep(.02)
    assert server.started
    try:
        with sim_lane.Session('iphone', UDID, keep_booted=False, lock_wait=0, load_wait=0, max_load=None) as session:
            report['boot_seconds'] = session.boot_seconds
            report['install_seconds'] = session.install(APP)
            for name, args, signal, thin in [
                ('phone-account', ['-fitcoach.baseURL', base, '-fitcoach.coachCookie', lane.cookie, '-fitcoach.screen', 'phone-account'], 'screenshot', False),
            ]:
                baseline, baseline_ok = (None, None) if thin else session.baseline()
                result = session.launch(info['bundle_id'], args, signal, 30, baseline, info['executable'], functional_thin=thin)
                output = RAW / f'iphone-unsigned-{name}.png'
                if result['frame']:
                    output.write_bytes(result['frame'].path.read_bytes())
                okay = bool(result['ready_signal'] and result['verdict'].get('non_blank') and result['frame'] and not result['errors'])
                if not thin:
                    okay = okay and result['verdict'].get('changed_from_baseline') is True
                record = {'name': name, 'ok': okay, 'screenshot': str(output) if output.exists() else None,
                          'ready_seconds': result['ready_seconds'], 'ready_signal': result['ready_signal'],
                          'baseline_stable': baseline_ok, 'verdict': result['verdict'],
                          'errors': result['errors'], 'launch_args': sim_lane.redact_args(args),
                          'size': sim_lane.png_size(output) if output.exists() else None}
                report['screens'].append(record)
                (RAW / f'iphone-unsigned-{name}-run.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
                session.terminate(info['bundle_id'])
                if not okay: break
            report['ok'] = len(report['screens']) == 1 and all(x['ok'] for x in report['screens'])
            report['fake_vendor_sends'] = len(lane.transport.sends)
            report['fake_vendor_checks'] = lane.transport.checks
        report['shutdown'] = True
    finally:
        server.should_exit = True; thread.join(timeout=10)
        gen.close(); mp.undo()
        (RAW / 'unsigned-phone-form-consumer.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))

print(json.dumps({'ok': report['ok'], 'screens': len(report['screens']), 'real_sms_sent': 0, 'shutdown': report.get('shutdown')}))
