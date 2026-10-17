#!/usr/bin/env python3
"""Build, provision, install, and prepare MOI on a connected iPhone."""
import argparse
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.cache'
SETTINGS = CACHE / 'install-settings.json'
APP = ROOT / 'build/Products/Release-iphoneos/MOI.app'
XCODEGEN_URL = 'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip'
XCODEGEN_SHA = '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806'
SETUP_MODELS = ('qwen3-0.6b', 'gemma-3-270m')


class SetupError(Exception):
    pass


def say(message):
    print(message, flush=True)


def retry(message):
    say('\n' + message)
    if not sys.stdin.isatty():
        raise SetupError('Complete that step, then rerun the same command. No data has been erased.')
    input('Press Return when ready to retry (Ctrl+C to stop): ')


def run(arguments, *, check=True, capture=True, input_text=None):
    result = subprocess.run([str(value) for value in arguments], cwd=ROOT, text=True,
                            input=input_text, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    if check and result.returncode:
        raise SetupError((result.stdout or '')[-5000:] + '\nCommand failed: ' + str(arguments[0]))
    return result


def read_settings():
    try:
        value = json.loads(SETTINGS.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(device, team, bundle):
    settings = read_settings()
    settings[device] = {'team': team, 'bundle': bundle}
    temp = SETTINGS.with_suffix('.tmp')
    temp.write_text(json.dumps(settings, indent=2) + '\n')
    temp.replace(SETTINGS)


def select(items, label, render):
    if len(items) == 1:
        return items[0]
    say('\nSelect ' + label + ':')
    for number, item in enumerate(items, 1):
        say(f'  {number}. {render(item)}')
    if not sys.stdin.isatty():
        raise SetupError(f'Multiple {label} choices. Set MOI_DEVICE_ID or MOI_TEAM_ID explicitly.')
    while True:
        answer = input('Number: ').strip()
        if answer.isdigit() and 1 <= int(answer) <= len(items):
            return items[int(answer) - 1]


def validate_bundle(bundle):
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise SetupError('MOI_BUNDLE_ID must be a reverse-domain identifier such as com.yourname.moi.')
    return bundle


def device_problem(details):
    hardware = details.get('hardwareProperties', {})
    properties = details.get('deviceProperties', {})
    if hardware.get('deviceType') != 'iPhone':
        return 'Choose a physical iPhone for this installer.'
    version = properties.get('osVersionNumber', '0').split('.')[0]
    if not version.isdigit() or int(version) < 17:
        return 'MOI requires iOS 17 or newer. This phone cannot run this build on its current iOS version.'
    if properties.get('developerModeStatus') != 'enabled':
        return ('Enable Settings → Privacy & Security → Developer Mode on the iPhone, restart, and confirm Turn On. '
                'If the menu is missing, open Xcode → Window → Devices and Simulators with the unlocked phone connected.')
    if details.get('connectionProperties', {}).get('pairingState') != 'paired':
        return 'Unlock the iPhone and tap Trust when asked to trust this computer.'
    return None


def receipt_state(receipt, request_id):
    # Never mistake an old installation's receipt for this run's success.
    if receipt.get('id') != request_id:
        return None
    state = receipt.get('state')
    if state == 'ready' and not (receipt.get('inference_verified') is True and receipt.get('serving') is True
                                 and receipt.get('endpoint', '').startswith('http://')):
        raise SetupError('The phone returned an incomplete readiness receipt. Open MOI and check Station.')
    return state


class Installer:
    def __init__(self):
        CACHE.mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix='setup-', dir=CACHE))
        self.counter = 0

    def device_json(self, arguments, *, optional=False, timeout=30):
        self.counter += 1
        output = self.work / f'device-{self.counter}.json'
        result = run(['xcrun', 'devicectl', *arguments, '--timeout', str(timeout), '--json-output', output], check=False)
        if result.returncode:
            if optional:
                return None
            raise SetupError((result.stdout or '')[-4000:])
        try:
            data = json.loads(output.read_text())
            if 'result' not in data:
                raise ValueError('No result in device response')
            return data['result']
        except (OSError, ValueError) as error:
            raise SetupError('Could not read devicectl JSON: ' + str(error)) from error

    def preflight(self):
        if sys.platform != 'darwin':
            raise SetupError('Installing an iPhone app requires a Mac with full Xcode. Linux and Windows are not supported.')
        if sys.version_info < (3, 9):
            raise SetupError('Python 3.9 or newer is required. Install/open a current full Xcode first.')
        xcode = run(['xcodebuild', '-version'], check=False)
        sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], check=False)
        if xcode.returncode or sdk.returncode:
            raise SetupError('Install and open full Xcode, accept its license, and install its iOS platform in Settings → Components. '
                             'Command Line Tools alone are insufficient. Then rerun ./start.sh.\n' + (sdk.stdout or '')[-1500:])
        say(xcode.stdout.strip())
        if run(['xcrun', '--find', 'devicectl'], check=False).returncode:
            raise SetupError('This Xcode lacks devicectl. Install Xcode 15 or newer; Xcode 26.6 is the tested version.')
        if shutil.disk_usage(ROOT).free < 2 * 1024**3:
            raise SetupError('Free at least 2 GB on the Mac before continuing; a clean build may need several GB more.')

    def choose_device(self):
        while True:
            explicit = os.environ.get('MOI_DEVICE_ID')
            if explicit:
                device = explicit
            else:
                result = self.device_json(['list', 'devices'])
                phones = [d for d in result.get('devices', []) if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'
                          and (d.get('connectionProperties', {}).get('tunnelState') in ('connected', 'connecting')
                               or d.get('connectionProperties', {}).get('transportType') == 'wired')]
                if not phones:
                    retry('Connect the iPhone by USB, unlock it, tap Trust, and keep it connected. Open Xcode → Window → Devices and Simulators if it does not appear.')
                    continue
                chosen = select(phones, 'iPhone', lambda d: d.get('deviceProperties', {}).get('name', 'iPhone') + ' · ' + d['identifier'])
                device = chosen['identifier']
            try:
                details = self.device_json(['device', 'info', 'details', '--device', device])
            except SetupError as error:
                retry(str(error) + '\nUnlock/trust the connected iPhone and open Xcode → Window → Devices and Simulators before retrying.')
                continue
            problem = device_problem(details)
            if problem:
                if 'iOS 17' in problem or 'physical iPhone' in problem:
                    raise SetupError(problem)
                retry(problem)
                continue
            hardware = details['hardwareProperties']
            say('Phone: ' + hardware.get('marketingName', 'iPhone') + ' · iOS ' + details['deviceProperties']['osVersionNumber'])
            return hardware['udid'], details

    def signing_team(self):
        explicit = os.environ.get('MOI_TEAM_ID')
        if explicit:
            if not re.fullmatch(r'[A-Z0-9]{10}', explicit):
                raise SetupError('MOI_TEAM_ID must be the 10-character Apple signing team ID.')
            return explicit
        while True:
            identities = run(['security', 'find-identity', '-v', '-p', 'codesigning'], check=False).stdout or ''
            fingerprints = {v.upper() for v in re.findall(r'\b[A-Fa-f0-9]{40}\b', identities)}
            certificates = run(['security', 'find-certificate', '-a', '-c', 'Apple Development', '-p'], check=False).stdout or ''
            teams = set()
            for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
                info = run(['openssl', 'x509', '-noout', '-subject', '-fingerprint', '-sha1', '-nameopt', 'RFC2253'], input_text=pem, check=False).stdout or ''
                fingerprint = re.search(r'Fingerprint=([A-Fa-f0-9:]+)', info)
                team = re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', info, re.M)
                if team and fingerprint and fingerprint[1].replace(':', '').upper() in fingerprints:
                    teams.add(team[1])
            if teams:
                return select(sorted(teams), 'signing team', str)
            retry('Add your Apple account in Xcode → Settings → Accounts. Select your team → Manage Certificates → + → Apple Development. '
                  'Alternatively set MOI_TEAM_ID to your team ID and let Xcode manage signing. MOI never asks for your Apple password.')

    def xcodegen(self):
        installed = shutil.which('xcodegen')
        if installed:
            return installed
        say('Downloading verified XcodeGen 2.46.0 into .cache/tools (no Homebrew required)…')
        archive = CACHE / 'tools/xcodegen-2.46.0.zip'
        archive.parent.mkdir(exist_ok=True)
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != XCODEGEN_SHA:
            with urllib.request.urlopen(XCODEGEN_URL, timeout=60) as response:
                data = response.read(8 * 1024**2)
            if hashlib.sha256(data).hexdigest() != XCODEGEN_SHA:
                raise SetupError('XcodeGen checksum mismatch. No downloaded tool was executed.')
            archive.write_bytes(data)
        with zipfile.ZipFile(io.BytesIO(archive.read_bytes())) as zipped:
            binaries = [name for name in zipped.namelist() if name.endswith('/bin/xcodegen')]
            if len(binaries) != 1:
                raise SetupError('Unexpected XcodeGen archive layout.')
            executable = archive.parent / 'xcodegen'
            executable.write_bytes(zipped.read(binaries[0]))
            executable.chmod(0o755)
        return str(executable)

    def build(self, device=None, team=None, bundle=None):
        run([self.xcodegen(), 'generate'], capture=False)
        args = ['xcodebuild', '-project', 'MOI.xcodeproj', '-scheme', 'MOI', '-sdk', 'iphoneos', '-configuration', 'Release',
                f'SYMROOT={ROOT}/build/Products', f'OBJROOT={ROOT}/build/Intermediates']
        if device:
            args += ['-destination', 'id=' + device, '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration',
                     'DEVELOPMENT_TEAM=' + team, 'PRODUCT_BUNDLE_IDENTIFIER=' + bundle]
        else:
            args += ['-destination', 'generic/platform=iOS', 'CODE_SIGNING_ALLOWED=NO']
        log = self.work / 'build.log'
        say('Building MOI. The first build downloads the pinned inference runtime; this can take several minutes.\nLog: ' + str(log))
        with log.open('w') as output:
            process = subprocess.Popen(args + ['build'], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
            while True:
                try:
                    code = process.wait(timeout=30)
                    break
                except subprocess.TimeoutExpired:
                    say('Still building… ' + str(log))
                except KeyboardInterrupt:
                    process.terminate()
                    process.wait()
                    raise
        if code:
            text = log.read_text(errors='replace')
            say('\n'.join(text.splitlines()[-35:]))
            if 'simulator runtime' in text.lower():
                raise SetupError('Compiling the app icon asset catalog needs an iOS Simulator runtime, even for phone builds. '
                                 'Open Xcode → Settings → Components, install the iOS platform/simulator, then rerun ./start.sh.')
            raise SetupError('Build failed. See the log above. For signing errors, check Xcode Accounts and your team; '
                             'for SDK/device errors, install the matching iOS platform in Xcode. Rerun after fixing the reported error.')

    def bundle(self, device, team=None):
        saved = read_settings().get(device, {})
        bundle = os.environ.get('MOI_BUNDLE_ID') or (saved.get('bundle') if not team or saved.get('team') == team else None)
        if not bundle:
            # Keep installations made with the original start script in place.
            apps = self.device_json(['device', 'info', 'apps', '--device', device], optional=True)
            candidates = [a['bundleIdentifier'] for a in (apps or {}).get('apps', [])
                          if a.get('name') == 'MOI' and a.get('builtByDeveloper') and
                          (a.get('bundleIdentifier') == 'com.moi.phone' or (team and a.get('bundleIdentifier') == f'com.moi.t{team.lower()}.phone'))]
            if candidates:
                bundle = select(candidates, 'MOI installation to update', str)
        if not bundle and team:
            bundle = f'com.moi.t{team.lower()}.phone'
        if not bundle:
            raise SetupError('Run ./start.sh first, or set MOI_BUNDLE_ID to the installed app identifier.')
        return validate_bundle(bundle)

    def copy_to(self, device, bundle, source, destination):
        self.device_json(['device', 'copy', 'to', '--device', device, '--domain-type', 'appDataContainer',
                          '--domain-identifier', bundle, '--source', str(source), '--destination', destination], timeout=300)

    def copy_model(self, device, bundle, model):
        # Directory copy creates Models on first install and merges without deleting other models.
        folder = self.work / 'Models'
        folder.mkdir(exist_ok=True)
        os.link(ROOT / 'models' / model['filename'], folder / model['filename'])
        say('Copying ' + model['name'] + ' to the iPhone…')
        try:
            self.copy_to(device, bundle, folder, 'Documents/Models')
        finally:
            (folder / model['filename']).unlink(missing_ok=True)

    def launch(self, device, bundle):
        while True:
            result = self.device_json(['device', 'process', 'launch', '--device', device, '--terminate-existing', bundle], optional=True)
            if result is not None:
                return
            retry('MOI is installed. Unlock the phone. If it says Untrusted Developer, open Settings → General → VPN & Device Management '
                  '→ Developer App and trust your own Apple developer profile. Keep the phone unlocked, then retry.')

    def wait_ready(self, device, bundle, request_id, seconds):
        say('Keep MOI open. Allow Local Network access if asked. Waiting for the phone to verify/load the model and run a real inference check…')
        deadline = time.monotonic() + seconds
        last_state = None
        while time.monotonic() < deadline:
            # A fresh destination avoids mistaking an old copied file for a new receipt.
            destination = self.work / 'phone-receipt.json'
            destination.unlink(missing_ok=True)
            copied = self.device_json(['device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer',
                                      '--domain-identifier', bundle, '--source', 'Documents/MOI-setup-result.json',
                                      '--destination', str(destination)], optional=True, timeout=10)
            if copied is not None and destination.exists():
                receipt = json.loads(destination.read_text())
                state = receipt_state(receipt, request_id)
                if state and state != last_state:
                    say('Phone: ' + receipt.get('message', state))
                    last_state = state
                if state == 'error':
                    raise SetupError('Phone setup needs attention: ' + receipt.get('message', 'Open MOI.') + '\nFix the issue and rerun ./start.sh.')
                if state == 'ready':
                    endpoint = receipt['endpoint'].rstrip('/')
                    try:
                        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        with opener.open(endpoint + '/', timeout=8) as response:
                            page = response.read(64 * 1024)
                        if b'Chat with MOI' not in page:
                            raise ValueError('Unexpected page')
                    except (OSError, ValueError):
                        raise SetupError('The phone loaded the model, passed inference, and started serving, but this Mac cannot reach its chat page. '
                                         'Join the same Wi-Fi, allow Local Network access for MOI, and check guest-network isolation. '
                                         'Open MOI → Connect to scan its QR. Phone URL: ' + endpoint)
                    say('\nMOI is ready. Model loaded, inference checked, and chat page reachable.\n'
                        'Open Connect on the iPhone and scan its QR from another device on the same Wi-Fi.\n'
                        'Website: ' + endpoint + '\nAPI base: ' + endpoint + '/v1\n'
                        'The QR pairs the browser automatically. API clients use the key shown in MOI → Connect.\n'
                        'You can disconnect USB now. Keep MOI open, on Wi-Fi, and powered.')
                    return
            time.sleep(2)
        raise SetupError('The app and model are installed, but readiness was not confirmed. Open MOI, trust your developer profile if asked, '
                         'allow Local Network access, and join Wi-Fi. Rerun ./start.sh to retry; models are reused. '
                         'Do not treat this timeout as a successful setup.')


def model_catalog():
    spec = importlib.util.spec_from_file_location('moi_download', ROOT / 'scripts/download-model.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.catalog()


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='No command means a full install with Qwen 3. Apple trust/signing steps still require the owner.')
    parser.add_argument('command', nargs='?', default='install', choices=('install', 'doctor', 'build', 'push-model'))
    parser.add_argument('model_id', nargs='?', help='Catalog model ID for push-model')
    parser.add_argument('--model', choices=SETUP_MODELS, default=os.environ.get('MOI_MODEL', SETUP_MODELS[0]), help='Model for full install (default: Qwen 3 0.6B)')
    parser.add_argument('--app-only', action='store_true', help='Install/launch without copying a model or automatic setup')
    parser.add_argument('--wait-seconds', type=int, default=180, help='Readiness timeout after launch (default: 180)')
    args = parser.parse_args()
    if args.model not in SETUP_MODELS or args.wait_seconds < 1:
        parser.error('Choose a supported setup model and a positive --wait-seconds value.')
    if (args.command == 'push-model') != bool(args.model_id):
        parser.error('Use a model ID only with push-model, e.g. ./start.sh push-model gemma-3-270m')
    CACHE.mkdir(exist_ok=True)
    with (CACHE / 'setup.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SetupError('Another MOI setup is running in this folder. Let it finish first.') from error
        installer = Installer()
        installer.preflight()
        if args.command == 'doctor':
            run(['xcrun', 'devicectl', 'list', 'devices'], capture=False)
            run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture=False)
            say('For full setup: ./start.sh\nFor help: ./start.sh --help')
            return
        if args.command == 'build':
            installer.build()
            say('Unsigned Release build succeeded. This does not install on a phone.')
            return
        device, _ = installer.choose_device()
        models = model_catalog()
        if args.command == 'push-model':
            if args.model_id not in models:
                raise SetupError('Unknown model. Choose: ' + ', '.join(models))
            bundle = installer.bundle(device)
            run([sys.executable, 'scripts/download-model.py', args.model_id], capture=False)
            installer.copy_model(device, bundle, models[args.model_id])
            say('Model copied. Open MOI → Model to select and load it. The phone enforces its RAM compatibility limits.')
            return
        team = installer.signing_team()
        bundle = installer.bundle(device, team)
        say('Signing team: ' + team + '\nApp identifier: ' + bundle)
        if not args.app_only:
            say('Downloading/verifying ' + models[args.model]['name'] + ' (no Hugging Face account needed)…')
            run([sys.executable, 'scripts/download-model.py', args.model], capture=False)
        installer.build(device, team, bundle)
        say('Installing the signed Release app…')
        installer.device_json(['device', 'install', 'app', '--device', device, str(APP)], timeout=300)
        save_settings(device, team, bundle)
        if args.app_only:
            installer.launch(device, bundle)
            say('App installed. Open Model → Load model, then Station → Start serving. Full setup: ./start.sh')
            return
        installer.copy_model(device, bundle, models[args.model])
        request_id = str(uuid.uuid4())
        request = installer.work / 'MOI-setup.json'
        request.write_text(json.dumps({'version': 1, 'id': request_id, 'modelID': args.model}))
        installer.copy_to(device, bundle, request, 'Documents/MOI-setup.json')
        installer.launch(device, bundle)
        installer.wait_ready(device, bundle, request_id, args.wait_seconds)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        say('\nSetup stopped. Rerun the same command when ready; the app and verified model downloads are kept.')
        sys.exit(130)
    except (SetupError, OSError, ValueError) as error:
        print('\nMOI setup: ' + str(error), file=sys.stderr)
        sys.exit(1)
