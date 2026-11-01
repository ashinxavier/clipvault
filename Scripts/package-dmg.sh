#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build.sh"
APP_BUNDLE="$ROOT/build/ClipVault.app"
DMG_PATH="$ROOT/build/ClipVault.dmg"
SIGNING_STATUS="unsigned"

if command -v codesign >/dev/null 2>&1; then
    if codesign --force --deep --sign - "$APP_BUNDLE"; then
        codesign --verify --deep --strict "$APP_BUNDLE"
        SIGNING_STATUS="ad-hoc signed (not Developer ID signed)"
    else
        printf 'Ad-hoc signing failed; refusing to label the package as signed.\n' >&2
        exit 1
    fi
fi

hdiutil create -volname ClipVault -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH"
printf 'Created local package: %s\n' "$DMG_PATH"
printf 'Signing status: %s. Notarization was not performed.\n' "$SIGNING_STATUS"
