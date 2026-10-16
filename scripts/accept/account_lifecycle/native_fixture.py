"""Launch the actual candidate's mounted native pages against the original isolated fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import pytest
import uvicorn
from fastapi import Request

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane
sys.path.insert(0, str(Path(os.environ['FITCOACH_TEST_BACKEND']) / 'tests'))
import test_phone as fixture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--platform', choices=('mac', 'iphone'), required=True)
    a = parser.parse_args()
    built = sim_lane.reuse_build(a.receipt, 'fitcoach-ios', ROOT, a.platform, 'FitCoach', 'Debug')
    source = Path(built['app_path'])
    actual = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(source.rglob('*')) if p.is_file()}
    assert built.get('product_artifacts') == actual, 'Candidate bundle differs from full build receipt'
    a.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fitcoach-native-account-') as scratch:
        scratch = Path(scratch)
        mp = pytest.MonkeyPatch()
        gen = fixture.lane.__wrapped__(scratch, mp)
        lane = next(gen)

        @fixture.api.app.post('/__account_fixture')
        async def control(request: Request):
            assert request.client.host == '127.0.0.1'
            fields = await request.json()
            lane.clock[0] += fields.get('advance', 0)
            if 'fail' in fields:
                lane.transport.fail = fields['fail']
            with sqlite3.connect(lane.path) as conn:
                if fields.get('risk'):
                    conn.execute('UPDATE coach_phone SET confirmed_at=? WHERE coach_id=?', (lane.clock[0] - 31*86400, lane.cid))
                    conn.commit()
                return {'student_intact': conn.execute('SELECT name FROM student WHERE coach_id=?', (lane.cid,)).fetchone() == ('原学员',),
                        'other_intact': fixture.tenancy.get_coach(conn, lane.other) is not None,
                        'phone_account_deleted': conn.execute('SELECT COUNT(*) FROM coach WHERE id NOT IN (?,?)', (lane.cid, lane.other)).fetchone()[0] == 0,
                        'sends': len(lane.transport.sends)}

        sock = socket.socket(); sock.bind(('127.0.0.1', 0))
        base = 'http://127.0.0.1:' + str(sock.getsockname()[1])
        server = uvicorn.Server(uvicorn.Config(fixture.api.app, log_level='error', access_log=False))
        thread = threading.Thread(target=server.run, kwargs={'sockets': [sock]}, daemon=True)
        thread.start()
        deadline = time.monotonic() + 15
        while not server.started and time.monotonic() < deadline:
            time.sleep(.02)
        assert server.started
        identity = 'test.tianli.fitcoach.account.' + uuid.uuid4().hex
        app = scratch / 'FitCoach.app'
        shutil.copytree(source, app, symlinks=True)
        info_path = app / ('Contents/Info.plist' if a.platform == 'mac' else 'Info.plist')
        info = plistlib.loads(info_path.read_bytes())
        original_identity = info['CFBundleIdentifier']
        info['CFBundleIdentifier'] = identity
        if a.platform == 'mac': info['LSUIElement'] = True
        info_path.write_bytes(plistlib.dumps(info))
        if a.platform == 'iphone':
            # Keep the real embedded Watch/widget structure valid under the disposable parent identity.
            for nested in app.rglob('Info.plist'):
                if nested == info_path: continue
                value = plistlib.loads(nested.read_bytes())
                for key in ('CFBundleIdentifier', 'WKCompanionAppBundleIdentifier'):
                    if isinstance(value.get(key), str) and value[key].startswith(original_identity):
                        value[key] = identity + value[key][len(original_identity):]
                nested.write_bytes(plistlib.dumps(value))
        try:
            if a.platform == 'mac':
                subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True, capture_output=True)
                env = {**os.environ, 'FITCOACH_ACCOUNT_OUT': str(a.out)}
                process = subprocess.run([str(app / 'Contents/MacOS' / info['CFBundleExecutable']), '--account-self-test', base],
                                         env=env, capture_output=True, text=True, timeout=180)
                (a.out / 'process.log').write_text(process.stdout + process.stderr)
            else:
                device = sim_lane.ensure_device('iphone')
                with sim_lane.Session('iphone', device['udid'], label='fitcoach-ios:account-native', lock_wait=0, load_wait=0) as session:
                    session.install(app)
                    launched = session.launch(identity, ['--account-self-test', base], 'log', 180, None, info['CFBundleExecutable'], functional_thin=True)
                    frame = launched.pop('frame')
                    if frame: shutil.copyfile(frame.path, a.out / 'simulator.png')
                    (a.out / 'launch.json').write_text(json.dumps(launched, ensure_ascii=False, indent=2))
                    try:
                        if launched['ready_signal'] != 'os_log' or launched['errors'] or frame is None:
                            raise RuntimeError('Native account suite did not complete with a rendered frame: ' +
                                               json.dumps(launched['errors'], ensure_ascii=False))
                        container = sim_lane.run(['xcrun', 'simctl', 'get_app_container', device['udid'], identity, 'data']).stdout.strip()
                        source = Path(container) / 'Documents/account-self-test'
                        if not (source / 'native.json').is_file():
                            raise RuntimeError('Native account completion report missing; refusing a first-screen-only result')
                        shutil.copytree(source, a.out, dirs_exist_ok=True)
                    finally:
                        session.terminate(identity)
                        sim_lane.run(['xcrun', 'simctl', 'uninstall', device['udid'], identity])
            report = json.loads((a.out / 'native.json').read_text())
            report['binding'] = {'receipt': str(a.receipt), 'receipt_sha256': hashlib.sha256(a.receipt.read_bytes()).hexdigest(),
                                 'product_artifacts': built.get('product_artifacts'), 'source': built['reuse'], 'platform': a.platform,
                                 'disposable_identity': identity}
            report['fixture'] = {'real_sms_sent': 0, 'fake_vendor_sends': len(lane.transport.sends), 'fake_vendor_checks': lane.transport.checks}
            (a.out / 'native.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            return 0 if report['checks'] and all(report['checks'].values()) and not report.get('error') else 1
        except sim_lane.Busy as exc:
            (a.out / 'native.json').write_text(json.dumps({'checks': {}, 'status': 'deferred', 'error': str(exc),
                'sms_transport': 'fake', 'real_sms_sent': 0}, ensure_ascii=False, indent=2) + '\n')
            return 75
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
            # Keep a structured failure even when the app never produces its report.
            (a.out / 'native.json').write_text(json.dumps({'checks': {}, 'status': 'failed', 'error': str(exc),
                'sms_transport': 'fake', 'real_sms_sent': 0}, ensure_ascii=False, indent=2) + '\n')
            return 1
        finally:
            server.should_exit = True; thread.join(timeout=10)
            gen.close(); mp.undo()
            if a.platform == 'mac': subprocess.run(['defaults', 'delete', identity], capture_output=True)


if __name__ == '__main__':
    try: raise SystemExit(main())
    except sim_lane.Busy as exc:
        print(str(exc)); raise SystemExit(75)
