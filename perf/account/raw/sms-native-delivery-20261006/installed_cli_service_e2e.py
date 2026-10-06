"""Installed CLI -> actual FastAPI routes -> disposable DB + existing fake gateway fixture."""
import hashlib
import json
import os
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
import uvicorn

SERVICE = Path('/Users/tianli/Apps/fitcoach/service')
RAW = Path('/Users/tianli/Apps/fitcoach/ios/01-源程序/perf/account/raw/sms-native-delivery-20261006')
CLI = Path('/Users/tianli/.local/bin/fitcoach').resolve()
sys.path.insert(0, str(SERVICE / 'tests'))
import test_phone as fixture

report = {'started_at': datetime.now(timezone.utc).isoformat(), 'cli': str(CLI),
          'cli_sha256': hashlib.sha256(CLI.read_bytes()).hexdigest(),
          'backend': str(SERVICE), 'transport': 'existing test_phone.lane fake gateway',
          'real_sms_sent': 0, 'commands': [], 'assertions': []}

def check(condition, label):
    assert condition, label
    report['assertions'].append(label)

with tempfile.TemporaryDirectory(prefix='fitcoach-installed-service-e2e-') as scratch:
    scratch = Path(scratch)
    mp = pytest.MonkeyPatch()
    gen = fixture.lane.__wrapped__(scratch, mp)
    lane = next(gen)
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    server = uvicorn.Server(uvicorn.Config(fixture.api.app, log_level='error', access_log=False))
    thread = threading.Thread(target=server.run, kwargs={'sockets': [sock]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while not server.started and time.monotonic() < deadline:
        time.sleep(.02)
    assert server.started
    env = {**os.environ, 'FITCOACH_BASE': base, 'FITCOACH_CLI_HOME': str(scratch / 'legacy')}
    credentials = scratch / 'legacy' / 'credentials.json'

    def run(*args, stdin=None, expected=0):
        proc = subprocess.run([str(CLI), *args, '--json'], input=stdin, text=True,
                              capture_output=True, timeout=25, env=env)
        # Never persist raw stdout with tokens/cookies/recovery keys.
        data = json.loads(proc.stdout) if proc.stdout else {}
        report['commands'].append({'command': list(args[:2]) if args[0] == 'phone' else [args[0]],
                                   'exit': proc.returncode, 'expected_exit': expected,
                                   'ok': data.get('ok'), 'error_code': data.get('code')})
        assert proc.returncode == expected, (args[:2], proc.returncode, data, proc.stderr)
        check('246810' not in proc.stdout, 'OTP is never printed to stdout')
        return data

    def send(purpose, number='', password=None, identity=None, request_id=None, expected=0):
        lane.clock[0] += 61
        args = ['phone', 'send', '--purpose', purpose, '--phone', number,
                '--request-id', request_id or secrets.token_hex(16), '--confirm-send']
        if password is not None: args += ['--password-stdin']
        if identity is not None: args += ['--identity-grant-file', str(identity)]
        return run(*args, stdin=(password + '\n') if password is not None else None, expected=expected)

    def verify(challenge, auth=False, code='246810', expected=0):
        args = ['phone', 'verify', '--challenge', challenge, '--code-stdin']
        if auth: args += ['--authenticated']
        data = run(*args, stdin=code+'\n', expected=expected)
        if expected: return data
        path = Path(data['grant_file'])
        check(stat.S_IMODE(path.stat().st_mode) == 0o600, 'verified grants are stored 0600')
        return path

    def issue(purpose, number='', password=None, identity=None):
        result = send(purpose, number, password, identity)
        return verify(result['challenge_id'], purpose in fixture.phone.AUTH_PURPOSES)

    try:
        hints = run('phone', 'hints')
        check(hints['sms']['enabled'] and hints['sms']['sign_name'] == '测试签名', 'real hints route uses fixture metadata')
        run('login', '--email', 'coach@example.com', '--password-stdin', stdin=fixture.PW+'\n')
        initial_credential = credentials.read_bytes()
        check(run('phone', 'account')['coach_id'] == lane.cid, 'legacy email account logs into actual service')
        rid = secrets.token_hex(16)
        sent = send('bind', fixture.N1, fixture.PW, request_id=rid)
        count = len(lane.transport.sends)
        again = send('bind', fixture.N1, fixture.PW, request_id=rid)
        check(again['challenge_id'] == sent['challenge_id'] and len(lane.transport.sends) == count, 'same request_id returns original challenge without second vendor call')
        healthy = credentials.read_bytes()
        verify(sent['challenge_id'], True, '000000', 4)
        check(credentials.read_bytes() == healthy, 'wrong authenticated OTP preserves healthy coach session')
        grant = verify(sent['challenge_id'], True)
        first = run('phone', 'bind', '--phone', fixture.N1, '--grant-file', str(grant), '--password-stdin', stdin=fixture.PW+'\n')
        key_file = Path(first['recovery_key_file'])
        recovery_key = json.loads(key_file.read_text())['recovery_key']
        check(not grant.exists() and stat.S_IMODE(key_file.stat().st_mode) == 0o600, 'first bind consumes grant and stores recovery key privately')
        bound_credential = credentials.read_bytes()
        credentials.write_bytes(initial_credential)
        run('phone', 'account', expected=6)
        check(not credentials.exists(), 'real revoked legacy session clears CLI credentials')
        credentials.write_bytes(bound_credential); credentials.chmod(0o600)
        old = issue('change_old', password=fixture.PW)
        new = issue('change_new', fixture.N2, fixture.PW)
        run('phone', 'bind', '--phone', fixture.N2, '--grant-file', str(new), '--password-stdin', stdin=fixture.PW+'\n', expected=4)
        check(new.exists() and old.exists(), 'missing old-number grant rejects without losing either grant')
        run('phone', 'bind', '--phone', fixture.N2, '--grant-file', str(new), '--old-grant-file', str(old), '--password-stdin', stdin=fixture.PW+'\n')
        check(not old.exists() and not new.exists(), 'two-number swap consumes both grants')
        account = run('phone', 'account')
        check(account['coach_id'] == lane.cid and account['phone_hint'].endswith('9000'), 'swap keeps original coach_id and returns masked new phone')
        login = issue('login', fixture.N2)
        run('phone', 'login', '--grant-file', str(login))
        check(not login.exists(), 'normal same-network SMS login consumes one-time grant')
        lane.conn.execute('UPDATE coach_phone SET confirmed_at=? WHERE coach_id=?', (lane.clock[0] - 31*86400, lane.cid)); lane.conn.commit()
        risk = issue('login', fixture.N2)
        before = credentials.read_bytes()
        run('phone', 'login', '--grant-file', str(risk), expected=4)
        check(risk.exists() and credentials.read_bytes() == before, 'risky SMS login retains grant and previous credential for supplemental proof')
        run('phone', 'login', '--grant-file', str(risk), '--ownership-stdin', stdin=json.dumps({'recovery_key': recovery_key}))
        # The real persistent ownership-attempt gate is ten per 900s. Respect it.
        lane.clock[0] += 901
        recovery = issue('recover', fixture.N2)
        run('phone', 'recover', '--grant-file', str(recovery), '--secrets-stdin', stdin=json.dumps({'new_password': 'Recovered independent password'}), expected=2)
        check(recovery.exists(), 'recovery requires independent proof before network consume')
        run('phone', 'recover', '--grant-file', str(recovery), '--secrets-stdin', stdin=json.dumps({'new_password': 'Recovered independent password', 'recovery_key': recovery_key}))
        check(not recovery.exists() and not credentials.exists(), 'recovery consumes grant and clears this CLI session')
        run('login', '--email', 'coach@example.com', '--password-stdin', stdin='Recovered independent password\n')
        check(run('phone', 'account')['coach_id'] == lane.cid, 'recovered password logs into original account')
        check(lane.conn.execute('SELECT name FROM student WHERE coach_id=?', (lane.cid,)).fetchone()[0] == '原学员', 'all phone changes preserve original student business data')
        check(fixture.tenancy.get_coach(lane.conn, lane.other) is not None, 'other coach remains isolated and unchanged')
        run('students', 'list')
        check(True, 'installed CLI still reaches original business list after phone lifecycle')
        legacy_creds = credentials
        env['FITCOACH_CLI_HOME'] = str(scratch / 'phone-only')
        credentials = scratch / 'phone-only' / 'credentials.json'
        reg = issue('register', fixture.N3)
        phone_reg = run('phone', 'register', '--grant-file', str(reg), '--display-name', '隔离手机教练', '--agreed')
        new_cid = phone_reg['coach_id']
        check(new_cid not in [lane.cid, lane.other] and not phone_reg['has_password'], 'verified SMS registration creates separate password-optional account')
        check(run('phone', 'account')['coach_id'] == new_cid, 'phone registration session reaches actual account endpoint')
        old = issue('change_old')
        new_phone = '13600136000'
        new = issue('change_new', new_phone, identity=old)
        run('phone', 'bind', '--phone', new_phone, '--grant-file', str(new), '--old-grant-file', str(old))
        check(run('phone', 'account')['coach_id'] == new_cid, 'phone-only dual verification swap reuses old grant as identity without password')
        identity = issue('identity')
        run('phone', 'set-password', '--identity-grant-file', str(identity), '--password-stdin', stdin='Phone newly set password\n')
        check(not identity.exists() and run('phone', 'account')['has_password'], 'phone-only account sets password after identity SMS and installs rotated cookie')
        stable = credentials.read_bytes()
        verify('missing-public-challenge', False, expected=6)
        check(credentials.read_bytes() == stable, 'anonymous OTP failure leaves authenticated phone account intact')
        send('change_new', fixture.N2, 'Phone newly set password', expected=4)
        check(credentials.read_bytes() == stable, 'occupied phone conflict preserves current session')
        expired = send('identity')
        lane.clock[0] += 301
        verify(expired['challenge_id'], True, expected=4)
        check(credentials.read_bytes() == stable, 'expired authenticated OTP with healthy ping preserves current session')
        run('account', 'delete', '--confirm', 'delete-account')
        check(not credentials.exists() and fixture.tenancy.get_coach(lane.conn, new_cid) is None, 'disposable phone-only account deletion clears session and tenant')
        check(lane.conn.execute('SELECT COUNT(*) FROM coach_phone WHERE coach_id=?', (new_cid,)).fetchone()[0] == 0, 'deletion removes phone binding without affecting legacy coach')
        rid = secrets.token_hex(16)
        lane.transport.fail = True
        send('register', '13500135000', request_id=rid, expected=1)
        count = len(lane.transport.sends)
        send('register', '13500135000', request_id=rid, expected=1)
        check(len(lane.transport.sends) == count, 'unknown delivery retry reuses durable unknown result without resending')
        lane.transport.fail = False
        mp.setenv('FITCOACH_SMS_DAILY_BUDGET', str(count))
        send('register', '13400134000', expected=4)
        check(len(lane.transport.sends) == count, 'actual persistent daily budget rejects before fake vendor call')
        report['fake_vendor_sends'] = len(lane.transport.sends)
        report['fake_vendor_checks'] = lane.transport.checks
        report['ok'] = True
    except Exception as exc:
        report['ok'] = False
        report['failure_type'] = type(exc).__name__
        raise
    finally:
        report['finished_at'] = datetime.now(timezone.utc).isoformat()
        report['command_count'] = len(report['commands'])
        report['assertion_count'] = len(report['assertions'])
        RAW.mkdir(parents=True, exist_ok=True)
        (RAW / 'installed-cli-service-e2e.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        server.should_exit = True
        thread.join(timeout=10)
        gen.close()
        mp.undo()

print(json.dumps({'ok': report['ok'], 'commands': report['command_count'], 'assertions': report['assertion_count'], 'real_sms_sent': 0}))
