#!/usr/bin/env python3
"""Real current-source candidate + headless iPhone simulator; never installs the Mac app.

Explicit target: --app PATH --receipt PATH, or FITCOACH_BASICS_APP/FITCOACH_BASICS_RECEIPT.
Receipt is the original shared sim_lane build receipt, not a claim that a candidate is installed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path.home() / 'Dev/tools/dev/lib/tools/macapp/ios'))
import sim_lane

FEATURES = ('settings', 'shortcuts', 'icloud', 'updates')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def bundle_files(app):
    return {str(path.relative_to(app)): sha(path) for path in sorted(app.rglob('*')) if path.is_file()}

def current_build(platform, receipt, *, prepare=False):
    def read():
        built = sim_lane.reuse_build(receipt, 'fitcoach-ios', ROOT, platform, scheme='FitCoach')
        artifacts = built.get('product_artifacts')
        if not artifacts or artifacts != bundle_files(Path(built['app_path'])):
            raise sim_lane.LaneError('Current bundle files differ from the full build receipt')
        return built

    try:
        return read()
    except sim_lane.LaneError:
        if not prepare or receipt != ROOT / f'build/accept/{platform}-build-receipt.json':
            raise
    result = subprocess.run([sys.executable, 'scripts/build_product_basics.py', '--platform', platform], cwd=ROOT)
    if result.returncode == 75:
        raise sim_lane.Busy(f'{platform} candidate build deferred by the shared build slot')
    if result.returncode:
        raise RuntimeError(f'{platform} candidate build failed (exit {result.returncode})')
    return read()

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def owner_snapshot():
    home = Path.home()
    paths = [home / 'Library/Preferences/cyou.tianli.fitcoachapp.plist',
             home / 'Library/Containers/cyou.tianli.fitcoachapp/Data/Library/Preferences/cyou.tianli.fitcoachapp.plist',
             Path('/Applications/上门体育.app/Contents/MacOS/FitCoach')]
    config = home / 'Library/Application Support/TianliApps/Configuration/fitcoach-mobile'
    if config.is_dir():
        paths += [p for p in config.rglob('*') if p.is_file()]
    return {str(path): sha(path) if path.is_file() else None for path in paths}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=os.environ.get('FITCOACH_BASICS_APP'))
    parser.add_argument('--receipt', type=Path, default=os.environ.get('FITCOACH_BASICS_RECEIPT', ROOT / 'build/accept/mac-build-receipt.json'))
    parser.add_argument('--ios-receipt', type=Path, default=ROOT / 'build/accept/iphone-build-receipt.json')
    args = parser.parse_args()
    spec = json.loads(os.environ['SOP_PRODUCT_BASICS_SPEC'])
    assert os.environ['SOP_APP_ID'] == 'fitcoach-ios'
    out = Path(os.environ['SOP_OUT_DIR']).resolve()
    assert out.is_relative_to(ROOT / 'perf/acceptance')
    run = out / ('product-basics-' + uuid.uuid4().hex)
    run.mkdir(parents=True)
    checks = {feature + '.iphone_executed': False for feature in ('settings', 'icloud', 'updates')}
    observations, binding = {}, {}
    error = None
    code = 1
    owner_before = owner_snapshot()
    suite = 'test.tianli.fitcoach.basics.' + uuid.uuid4().hex
    try:
        for platform, receipt in (('mac', args.receipt), ('iphone', args.ios_receipt)):
            result = current_build(platform, receipt, prepare=args.app is None)
            artifacts = result.get('product_artifacts')
            assert artifacts and artifacts == bundle_files(Path(result['app_path'])), 'Current bundle files differ from the build receipt'
            binding[platform] = {'receipt': str(receipt.resolve()), 'receipt_sha256': sha(receipt),
                                 'app': result['app_path'], 'executable_sha256': result['executable_sha256'],
                                 'artifact_files': artifacts,
                                 'source': result['reuse'], 'signing': result['signing']}
        app = (args.app or Path(binding['mac']['app'])).resolve()
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
        checks['settings.current_source_binary'] = bundle_files(app) == binding['mac']['artifact_files'] and info['CFBundleIdentifier'] == 'cyou.tianli.fitcoachapp'
        assert checks['settings.current_source_binary'], 'Target is stale; build current source, then pass --app/--receipt (candidate is not installed)'
        binding['target'] = {'app': str(app), 'installed': app == Path('/Applications/上门体育.app'),
                             'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'sha256': sha(executable)}
        # A disposable identity isolates NSUserDefaults and avoids the installed sandbox/Keychain domain.
        clone = ROOT / 'build/accept' / suite / 'FitCoach.app'
        clone.parent.mkdir(parents=True)
        shutil.copytree(app, clone, symlinks=True)
        info['CFBundleIdentifier'] = suite
        info['LSUIElement'] = True
        (clone / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        signed = subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(clone)], capture_output=True, text=True)
        (run / 'signature.log').write_text(signed.stdout + signed.stderr)
        assert signed.returncode == 0
        env = dict(os.environ, FITCOACH_BASICS_OUT=str(run / 'mac'))
        for flag, log in (('--ui-self-test', 'mac-ui.log'), ('--ui-self-test-readback', 'mac-readback.log')):
            result = subprocess.run([str(clone / 'Contents/MacOS' / info['CFBundleExecutable']), flag], env=env, capture_output=True, text=True, timeout=90)
            (run / log).write_text(result.stdout + result.stderr)
            assert result.returncode == 0, log + ': product executable failed'
        mac = json.loads((run / 'mac/ui.json').read_text())
        mac_readback = json.loads((run / 'mac/readback.json').read_text())
        observations['mac'] = mac
        observations['mac_readback'] = mac_readback
        checks.update(mac['checks'])
        checks['settings.persisted_readback'] = mac_readback.get('settings.persisted_readback') is True
        checks['shortcuts.persisted_readback'] = mac_readback.get('shortcuts.persisted_readback') is True
        checks['updates.persisted_options'] = mac_readback.get('updates.persisted_options') is True

        # Shared runner owns device locks, load gates, boot, app install/launch and noninteractive screenshots.
        ios_app = Path(binding['iphone']['app'])
        device = sim_lane.ensure_device('iphone')
        ios_info = sim_lane.bundle_info(ios_app)
        for flag, stem in (('--ui-self-test', 'ios-ui'), ('--ui-self-test-readback', 'ios-readback')):
            # A completed shutdown is the boundary between the two real processes.
            # Re-launching immediately after terminate can wedge CoreSimulator's
            # --terminate-running-process request for 120s. Keep the same persistent
            # test device/data, release the original lane normally, then cold boot.
            with sim_lane.Session('iphone', device['udid'], label='fitcoach-ios:product-basics:' + stem, lock_wait=0, load_wait=0) as session:
                if flag == '--ui-self-test':
                    session.install(ios_app)
                launched = session.launch(ios_info['bundle_id'], [flag], 'log', 90, None, ios_info['executable'], functional_thin=True)
                frame = launched.pop('frame')
                launched['ok'] = (launched['ready_signal'] == 'os_log' and launched['verdict']['non_blank'] is True
                                  and frame is not None and not launched['errors'])
                launched['udid'] = device['udid']
                launched['environment'] = 'simulator'
                if frame:
                    shutil.copyfile(frame.path, run / (stem + '.png'))
                write(run / (stem + '-launch.json'), launched)
                if not launched['ok']:
                    raise RuntimeError('Headless iPhone product run failed: ' + json.dumps(launched['errors'], ensure_ascii=False))
                container = sim_lane.run(['xcrun', 'simctl', 'get_app_container', device['udid'], 'cyou.tianli.fitcoachapp', 'data']).stdout.strip()
                source = Path(container) / 'Documents/product-basics'
                target = run / 'iphone'
                shutil.copytree(source, target, dirs_exist_ok=True)
                session.terminate(ios_info['bundle_id'])
        ios = json.loads((run / 'iphone/ui.json').read_text())
        ios_readback = json.loads((run / 'iphone/readback.json').read_text())
        observations['iphone'] = ios
        observations['iphone_readback'] = ios_readback
        for feature in ('settings', 'icloud', 'updates'):
            checks[feature + '.iphone_executed'] = 'error' not in ios
        for key, value in ios['checks'].items():
            checks[key.split('.')[0] + '.iphone_' + key.split('.', 1)[1]] = value is True
            if key in checks:
                checks[key] = checks[key] and value is True
        checks['settings.iphone_fresh_process'] = ios_readback.get('settings.persisted_readback') is True
        checks['updates.iphone_fresh_process'] = ios_readback.get('updates.persisted_options') is True
        assert 'error' not in mac and 'error' not in ios, 'In-product suite did not finish'
        code = 0 if all(checks.values()) else 1
    except sim_lane.Busy as exc:
        error = str(exc)
        code = 75
    except Exception as exc:
        error = str(exc)
        checks['settings.suite_completed'] = False
    finally:
        # Dedicated test domains only. Production preferences and iCloud paths are never written.
        subprocess.run(['/usr/bin/defaults', 'delete', suite], capture_output=True)
        subprocess.run(['/usr/bin/defaults', 'delete', 'test.tianli.fitcoach.product-basics'], capture_output=True)
        subprocess.run(['/usr/bin/defaults', 'delete', 'test.tianli.fitcoach.product-basics.peer'], capture_output=True)
    for feature in FEATURES:
        for key in spec['features'][feature]['required_checks']:
            checks.setdefault(key, False)
    owner_after = owner_snapshot()
    checks['settings.production_data_preserved'] = owner_before == owner_after
    if not checks['settings.production_data_preserved']:
        code = 1
    if code != 75 and not all(checks.values()):
        code = 1
    artifacts = {}
    for path in run.rglob('*'):
        if path.is_file() and not path.is_relative_to(run / 'fixture'):
            artifacts[str(path.relative_to(ROOT))] = sha(path)
    raw = run / 'raw.json'
    write(raw, {'schema_version': 1, 'app_id': 'fitcoach-ios', 'spec_digest': spec['digest'], 'checks': checks,
                'binding': binding, 'observations': observations, 'artifacts': artifacts, 'error': error,
                'owner_before': owner_before, 'owner_after': owner_after,
                'cloud_scope': 'isolated two-store push/pull and remote changes; Apple cross-device transmission not verified'})
    features = {feature: {'result': 'passed' if all(value for key, value in checks.items() if key.startswith(feature + '.')) else 'failed',
                          'method': 'ui_automation' if feature == 'settings' else 'real_product',
                          'evidence': str(raw.relative_to(ROOT)), 'evidence_sha256': sha(raw),
                          'checks': [key for key in checks if key.startswith(feature + '.')]}
                for feature in FEATURES}
    detail = {'schema_version': 1, 'app_id': 'fitcoach-ios', 'spec_digest': spec['digest'], 'features': features,
              'summary': 'Mac候选和iPhone模拟器基础能力' + ('通过' if code == 0 else '未通过'), 'error': error}
    write(out / 'product_basics.detail.json', detail)
    print(json.dumps({'summary': detail['summary'], 'error': error, 'raw': str(raw), 'failed': [key for key, value in checks.items() if not value]}, ensure_ascii=False))
    return code

if __name__ == '__main__':
    raise SystemExit(main())
