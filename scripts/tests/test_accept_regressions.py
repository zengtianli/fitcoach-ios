"""Fail-closed candidate selection and original media-player delegation; no GUI/network."""
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest


ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def basics():
    return load('fitcoach_basics_regression', ROOT / 'scripts/accept/product_basics.py')


@pytest.fixture
def candidate(tmp_path):
    app = tmp_path / 'FitCoach.app'
    app.mkdir()
    (app / 'FitCoach.debug.dylib').write_bytes(b'current Swift implementation')
    return app


def test_reuses_current_full_bundle_without_build(basics, candidate, monkeypatch):
    built = {'app_path': str(candidate), 'product_artifacts': basics.bundle_files(candidate)}
    monkeypatch.setattr(basics.sim_lane, 'reuse_build', Mock(return_value=built))
    build = Mock()
    monkeypatch.setattr(basics.subprocess, 'run', build)
    assert basics.current_build('mac', basics.ROOT / 'build/accept/mac-build-receipt.json', prepare=True) == built
    build.assert_not_called()


def test_stale_default_candidate_rebuilds_then_rechecks(basics, candidate, monkeypatch):
    built = {'app_path': str(candidate), 'product_artifacts': basics.bundle_files(candidate)}
    reuse = Mock(side_effect=[basics.sim_lane.LaneError('source changed'), built])
    monkeypatch.setattr(basics.sim_lane, 'reuse_build', reuse)
    build = Mock(return_value=SimpleNamespace(returncode=0))
    monkeypatch.setattr(basics.subprocess, 'run', build)
    assert basics.current_build('mac', basics.ROOT / 'build/accept/mac-build-receipt.json', prepare=True) == built
    assert reuse.call_count == 2
    assert build.call_count == 1


def test_modified_debug_dylib_is_rejected_for_explicit_target(basics, candidate, monkeypatch):
    built = {'app_path': str(candidate), 'product_artifacts': basics.bundle_files(candidate)}
    (candidate / 'FitCoach.debug.dylib').write_bytes(b'tampered Swift implementation')
    monkeypatch.setattr(basics.sim_lane, 'reuse_build', Mock(return_value=built))
    build = Mock()
    monkeypatch.setattr(basics.subprocess, 'run', build)
    with pytest.raises(basics.sim_lane.LaneError, match='full build receipt'):
        basics.current_build('mac', basics.ROOT / 'build/accept/mac-build-receipt.json')
    build.assert_not_called()


def test_build_busy_is_deferred_without_stale_fallback(basics, monkeypatch):
    reuse = Mock(side_effect=basics.sim_lane.LaneError('stale'))
    monkeypatch.setattr(basics.sim_lane, 'reuse_build', reuse)
    monkeypatch.setattr(basics.subprocess, 'run', Mock(return_value=SimpleNamespace(returncode=75)))
    with pytest.raises(basics.sim_lane.Busy):
        basics.current_build('iphone', basics.ROOT / 'build/accept/iphone-build-receipt.json', prepare=True)
    assert reuse.call_count == 1


def test_failed_build_cannot_promote_old_receipt(basics, monkeypatch):
    reuse = Mock(side_effect=basics.sim_lane.LaneError('stale'))
    monkeypatch.setattr(basics.sim_lane, 'reuse_build', reuse)
    monkeypatch.setattr(basics.subprocess, 'run', Mock(return_value=SimpleNamespace(returncode=1)))
    with pytest.raises(RuntimeError, match='candidate build failed'):
        basics.current_build('mac', basics.ROOT / 'build/accept/mac-build-receipt.json', prepare=True)
    assert reuse.call_count == 1


def setup_acceptance(basics, tmp_path, monkeypatch):
    monkeypatch.setattr(basics, 'ROOT', tmp_path)
    monkeypatch.setattr(basics, 'owner_snapshot', lambda: {})
    monkeypatch.setattr(basics.sys, 'argv', ['product_basics.py'])
    for key in ('FITCOACH_BASICS_APP', 'FITCOACH_BASICS_RECEIPT'):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv('SOP_APP_ID', 'fitcoach-ios')
    monkeypatch.setenv('SOP_OUT_DIR', str(tmp_path / 'perf/acceptance'))
    monkeypatch.setenv('SOP_PRODUCT_BASICS_SPEC', json.dumps({'digest': 'test', 'features': {
        'settings': {'required_checks': ['settings.interaction']},
        'shortcuts': {'required_checks': ['shortcuts.action_path']},
        'icloud': {'required_checks': ['icloud.push_pull']},
        'updates': {'required_checks': ['updates.check_result']}}}))


def test_fixed_command_selects_candidate_without_touching_installed_app(basics, tmp_path, monkeypatch):
    setup_acceptance(basics, tmp_path, monkeypatch)
    app = tmp_path / 'candidate/FitCoach.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/MacOS/FitCoach').write_bytes(b'test executable')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'cyou.tianli.fitcoachapp', 'CFBundleExecutable': 'FitCoach',
        'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1'}))
    artifacts = basics.bundle_files(app)
    built = {'app_path': str(app), 'product_artifacts': artifacts, 'executable_sha256': 'test',
             'reuse': {'source': 'current'}, 'signing': {}}

    def candidate_build(platform, receipt, *, prepare):
        assert prepare is True
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(built))
        return built

    monkeypatch.setattr(basics, 'current_build', candidate_build)
    # Stop at a real failure boundary before any product process or simulator starts.
    monkeypatch.setattr(basics.subprocess, 'run', Mock(return_value=SimpleNamespace(
        returncode=1, stdout='', stderr='test signature failure')))
    assert basics.main() == 1
    raw = next((tmp_path / 'perf/acceptance').glob('product-basics-*/raw.json'))
    binding = json.loads(raw.read_text())['binding']['target']
    assert binding['app'] == str(app)
    assert binding['installed'] is False


def test_fixed_command_keeps_build_deferred_as_75(basics, tmp_path, monkeypatch):
    setup_acceptance(basics, tmp_path, monkeypatch)
    monkeypatch.setattr(basics, 'current_build', Mock(side_effect=basics.sim_lane.Busy('build slot busy')))
    monkeypatch.setattr(basics.subprocess, 'run', Mock())
    assert basics.main() == 75
    detail = json.loads((tmp_path / 'perf/acceptance/product_basics.detail.json').read_text())
    assert detail['error'] == 'build slot busy'
    assert all(row['result'] == 'failed' for row in detail['features'].values())


def test_account_cli_uses_build_slot_and_defers_without_compiling(basics, tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, 'product_basics', basics)
    account = load('fitcoach_account_regression', ROOT / 'scripts/accept/account_lifecycle.py')
    monkeypatch.setattr(account, 'ROOT', tmp_path)
    monkeypatch.setattr(account, 'owner_snapshot', lambda: {})
    monkeypatch.setattr(account, 'backend_python', lambda _: sys.executable)
    monkeypatch.setenv('SOP_OUT_DIR', str(tmp_path / 'perf/acceptance'))
    monkeypatch.setattr(account.sim_lane, 'BuildSlot', Mock(side_effect=account.sim_lane.Busy('build slot busy')))
    run = Mock()
    monkeypatch.setattr(account.subprocess, 'run', run)
    assert account.main() == 75
    run.assert_not_called()


@pytest.mark.parametrize('exit_code', [0, 1, 75])
def test_media_uses_original_player_and_preserves_verdict(exit_code, monkeypatch):
    media = load('fitcoach_media_regression', ROOT / 'scripts/accept/media_playback.py')
    files = [ROOT / 'shots/media/sample.mp4', ROOT / 'shots/example.png']
    monkeypatch.setenv('SOP_CONFIG', json.dumps({'media': ['shots/**/*']}))
    monkeypatch.setattr(media.app_sop, 'media_files', lambda _: files)
    page = Mock(return_value={'videos': [{'current_time': 2.0}]})
    player = SimpleNamespace(load_page=page)

    def original_main(args):
        assert args == []
        player.load_page('https://example.invalid/', 1440, 900, '/tmp/example.png', play=True, wait_ms=20000)
        raise SystemExit(exit_code)

    player.main = original_main
    spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda _: None))
    monkeypatch.setattr(media.importlib.util, 'spec_from_file_location', lambda *_: spec)
    monkeypatch.setattr(media.importlib.util, 'module_from_spec', lambda _: player)
    with pytest.raises(SystemExit) as result:
        media.main()
    assert result.value.code == exit_code
    assert page.call_args.kwargs == {'play': True, 'wait_ms': 60000}
    assert json.loads(media.os.environ['SOP_CONFIG'])['media'] == ['shots/media/sample.mp4', 'shots/example.png']


def test_media_refuses_empty_video_coverage(monkeypatch):
    media = load('fitcoach_media_regression', ROOT / 'scripts/accept/media_playback.py')
    monkeypatch.setenv('SOP_CONFIG', '{}')
    monkeypatch.setattr(media.app_sop, 'media_files', lambda _: [ROOT / 'shots/example.png'])
    with pytest.raises(SystemExit, match='No actual local operation video'):
        media.main()
