#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
MOI — mom's old iPhone

./start.sh doctor          Check Xcode, signing, and connected phones
./start.sh build           Build an unsigned device app (compile check)
./start.sh install         Build, sign, install, and launch on your iPhone
./start.sh push-model ID   Copy a downloaded catalog model to the app

Optional environment settings:
  MOI_TEAM_ID       Apple team ID (auto-detected from your signing certificate)
  MOI_DEVICE_ID     CoreDevice identifier or device UDID (required if >1 phone)
  MOI_BUNDLE_ID     Unique bundle ID (default com.moi.phone)

Before first install: add your Apple account in Xcode Settings → Accounts,
connect/unlock/trust the phone, and enable Developer Mode on the phone.
EOF
}

require() { command -v "$1" >/dev/null || { echo "Missing $1. Install it before continuing." >&2; exit 1; }; }
require xcodebuild
require python3
mkdir -p .cache build

device() {
    if [[ -n "${MOI_DEVICE_ID:-}" ]]; then printf '%s' "$MOI_DEVICE_ID"; return; fi
    xcrun devicectl list devices --json-output .cache/devices.json >/dev/null
    python3 - <<'PY'
import json,sys
data=json.load(open('.cache/devices.json'))
devices=[d for d in data.get('result',{}).get('devices',[]) if d.get('hardwareProperties',{}).get('deviceType')=='iPhone']
if len(devices)!=1:
    sys.exit('Connect one iPhone or set MOI_DEVICE_ID. Run ./start.sh doctor for the device list.')
print(devices[0]['identifier'])
PY
}

generate() {
    if ! command -v xcodegen >/dev/null; then
        require brew
        HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
    fi
    xcodegen generate
}

case "${1:-install}" in
    doctor)
        xcodebuild -version
        xcrun devicectl list devices
        security find-identity -v -p codesigning
        xcrun xcdevice list --timeout 5
        ;;
    build)
        generate
        xcodebuild -project MOI.xcodeproj -target MOI -sdk iphoneos -configuration Release \
            SYMROOT="$PWD/build/Products" OBJROOT="$PWD/build/Intermediates" \
            CODE_SIGNING_ALLOWED=NO build
        ;;
    install)
        generate
        if [[ -z "${MOI_TEAM_ID:-}" ]]; then
            MOI_TEAM_ID="$(security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p' || true)"
            if [[ -z "$MOI_TEAM_ID" ]]; then
                echo 'Add your Apple account in Xcode Settings → Accounts, or set MOI_TEAM_ID and select your team in Xcode.' >&2
                exit 1
            fi
        fi
        target_device="$(device)"
        bundle="${MOI_BUNDLE_ID:-com.moi.phone}"
        xcrun devicectl device info details --device "$target_device" --json-output .cache/install-device.json >/dev/null
        signing_device="$(python3 - <<'PY'
import json
d=json.load(open('.cache/install-device.json'))
print(d['result']['hardwareProperties']['udid'])
PY
)"
        xcodebuild -project MOI.xcodeproj -scheme MOI -sdk iphoneos -configuration Release \
            -destination "id=$signing_device" SYMROOT="$PWD/build/Products" OBJROOT="$PWD/build/Intermediates" \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
            DEVELOPMENT_TEAM="$MOI_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$bundle" build
        xcrun devicectl device install app --device "$target_device" build/Products/Release-iphoneos/MOI.app
        if ! xcrun devicectl device process launch --device "$target_device" "$bundle"; then
            echo 'MOI was installed, but iOS did not launch it. Unlock the phone and open MOI.' >&2
            echo 'If it says Untrusted Developer: Settings → General → VPN & Device Management → Developer App → Trust, then reopen MOI.' >&2
            exit 1
        fi
        echo 'MOI is installed. Open it, allow Local Network access, choose a model, and start serving.'
        ;;
    push-model)
        [[ -n "${2:-}" ]] || { usage; exit 1; }
        python3 scripts/download-model.py "$2"
        model_file="$(python3 - "$2" <<'PY'
import runpy,sys
ns=runpy.run_path('scripts/download-model.py')
print(ns['catalog']()[sys.argv[1]]['filename'])
PY
)"
        target_device="$(device)"
        xcrun devicectl device copy to --device "$target_device" \
            --domain-type appDataContainer --domain-identifier "${MOI_BUNDLE_ID:-com.moi.phone}" \
            --source "models/$model_file" --destination "Documents/Models/$model_file"
        ;;
    *) usage; exit 1 ;;
esac
