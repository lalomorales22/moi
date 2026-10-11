#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Select full Xcode for this process without changing the Mac's global setting.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_xcode="$(xcode-select -p 2>/dev/null || true)"
    if [[ -d "$selected_xcode/Platforms/iPhoneOS.platform" ]]; then
        export DEVELOPER_DIR="$selected_xcode"
    elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
if ! command -v python3 >/dev/null; then
    echo 'Install and open full Xcode from the Mac App Store first, then rerun ./start.sh.' >&2
    exit 1
fi
exec python3 scripts/setup.py "$@"
