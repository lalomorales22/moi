"""Installer contracts; uses isolated files and mocked devices, never the user's phone."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('moi_setup', Path(__file__).resolve().parents[1] / 'scripts/setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def test_device_requirements(self):
        details = {'hardwareProperties': {'deviceType': 'iPhone'},
                   'deviceProperties': {'osVersionNumber': '17.0', 'developerModeStatus': 'enabled'},
                   'connectionProperties': {'pairingState': 'paired'}}
        self.assertIsNone(setup.device_problem(details))
        details['deviceProperties']['developerModeStatus'] = 'disabled'
        self.assertIn('Developer Mode', setup.device_problem(details))
        details['deviceProperties']['osVersionNumber'] = '16.7'
        self.assertIn('iOS 17', setup.device_problem(details))
        details['hardwareProperties']['deviceType'] = 'iPad'
        self.assertIn('physical iPhone', setup.device_problem(details))

    def test_no_stale_or_partial_success(self):
        ready = {'id': 'current', 'state': 'ready', 'serving': True, 'inference_verified': True, 'endpoint': 'http://192.0.2.10:8080'}
        self.assertIsNone(setup.receipt_state(ready, 'different-run'))
        self.assertEqual(setup.receipt_state(ready, 'current'), 'ready')
        for field in ['serving', 'inference_verified', 'endpoint']:
            incomplete = dict(ready)
            del incomplete[field]
            with self.assertRaises(setup.SetupError):
                setup.receipt_state(incomplete, 'current')

    def test_saved_bundle_and_existing_app_are_preserved(self):
        installer = object.__new__(setup.Installer)
        with patch.dict(setup.os.environ, {}, clear=True), patch.object(setup, 'read_settings', return_value={'phone': {'team': 'ABCDEFGHIJ', 'bundle': 'com.my.moi'}}):
            self.assertEqual(installer.bundle('phone', 'ABCDEFGHIJ'), 'com.my.moi')
        with patch.dict(setup.os.environ, {}, clear=True), patch.object(setup, 'read_settings', return_value={}), \
             patch.object(installer, 'device_json', return_value={'apps': [{'name': 'MOI', 'builtByDeveloper': True, 'bundleIdentifier': 'com.moi.phone'}]}):
            self.assertEqual(installer.bundle('phone', 'ABCDEFGHIJ'), 'com.moi.phone')
        with patch.dict(setup.os.environ, {}, clear=True), patch.object(setup, 'read_settings', return_value={}), patch.object(installer, 'device_json', return_value={'apps': []}):
            self.assertEqual(installer.bundle('phone', 'ABCDEFGHIJ'), 'com.moi.tabcdefghij.phone')

    def test_ambiguous_devices_do_not_silently_pick_first(self):
        with patch.object(setup.sys.stdin, 'isatty', return_value=False), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(setup.SetupError):
                setup.select(['phone1', 'phone2'], 'iPhone', str)

    def test_invalid_bundle_is_rejected(self):
        for bundle in ['bad value', 'com.moi;echo', '-setting=value', 'moi', '../moi']:
            with self.assertRaises(setup.SetupError):
                setup.validate_bundle(bundle)

    def test_full_install_stages_model_and_request_before_launch(self):
        events = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            class FakeInstaller:
                work = root
                def preflight(self): events.append('preflight')
                def choose_device(self): return 'phone', {}
                def signing_team(self): return 'ABCDEFGHIJ'
                def bundle(self, *_): return 'com.example.moi'
                def build(self, *_): events.append('build')
                def device_json(self, args, **_):
                    self.assert_install(args)
                    events.append('install')
                def assert_install(self, args):
                    assert args[:3] == ['device', 'install', 'app']
                def copy_model(self, *args): events.append('model')
                def copy_to(self, device, bundle, source, destination):
                    request = json.loads(source.read_text())
                    assert request['version'] == 1 and request['modelID'] == 'qwen3-0.6b'
                    assert set(request) == {'id', 'modelID', 'version'}, 'No credentials in setup request'
                    assert destination == 'Documents/MOI-setup.json'
                    self.request_id = request['id']
                    events.append('request')
                def launch(self, *_): events.append('launch')
                def wait_ready(self, device, bundle, request_id, timeout):
                    assert request_id == self.request_id
                    events.append('verified')
            with patch.object(setup, 'CACHE', root), patch.object(setup, 'Installer', FakeInstaller), \
                 patch.object(setup, 'save_settings'), patch.object(setup, 'run', side_effect=lambda *a, **k: events.append('download')), \
                 patch.object(setup.sys, 'argv', ['setup.py']), patch.dict(setup.os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
                setup.main()
        self.assertEqual(events, ['preflight', 'download', 'build', 'install', 'model', 'request', 'launch', 'verified'])

    def test_receipt_timeout_is_failure(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(setup, 'CACHE', Path(temporary)), contextlib.redirect_stdout(io.StringIO()):
            installer = setup.Installer()
            with patch.object(setup.time, 'monotonic', side_effect=[0, 2]):
                with self.assertRaisesRegex(setup.SetupError, 'readiness was not confirmed'):
                    installer.wait_ready('phone', 'com.example.moi', 'request', 1)

    def test_phone_error_is_failure(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(setup, 'CACHE', Path(temporary)), contextlib.redirect_stdout(io.StringIO()):
            installer = setup.Installer()
            def copy_receipt(args, **_):
                Path(args[args.index('--destination') + 1]).write_text(json.dumps({'id': 'request', 'state': 'error', 'message': 'Model checksum did not match.'}))
                return {}
            with patch.object(installer, 'device_json', side_effect=copy_receipt):
                with self.assertRaisesRegex(setup.SetupError, 'checksum'):
                    installer.wait_ready('phone', 'com.example.moi', 'request', 1)

    def test_ready_requires_reachable_chat_and_normalizes_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(setup, 'CACHE', Path(temporary)), contextlib.redirect_stdout(io.StringIO()):
            installer = setup.Installer()
            def copy_receipt(args, **_):
                Path(args[args.index('--destination') + 1]).write_text(json.dumps({
                    'id': 'request', 'state': 'ready', 'inference_verified': True, 'serving': True, 'endpoint': 'http://192.0.2.1:8080/'}))
                return {}
            class Opener:
                def open(self, url, **_):
                    assert url == 'http://192.0.2.1:8080/'
                    return io.BytesIO(b'<title>Chat with MOI</title>')
            with patch.object(installer, 'device_json', side_effect=copy_receipt), patch.object(setup.urllib.request, 'build_opener', return_value=Opener()):
                installer.wait_ready('phone', 'com.example.moi', 'request', 1)
            with patch.object(installer, 'device_json', side_effect=copy_receipt), patch.object(setup.urllib.request, 'build_opener', side_effect=OSError('No route')):
                with self.assertRaisesRegex(setup.SetupError, 'cannot reach'):
                    installer.wait_ready('phone', 'com.example.moi', 'request', 1)


if __name__ == '__main__':
    unittest.main()
