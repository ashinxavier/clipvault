#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_PATH="${MACOS_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK_PATH" ]]; then
    printf 'Required macOS 26.5 SDK not found: %s\nSet MACOS_SDK_PATH to a compatible SDK.\n' "$SDK_PATH" >&2
    exit 1
fi

APP_BUNDLE="$ROOT/build/ClipVault.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT/Sources/ClipVault/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Sources/ClipVault/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

SOURCE_FILES=()
while IFS= read -r source; do SOURCE_FILES+=("$source"); done < <(find "$ROOT/Sources/ClipVault" -type f -name '*.swift' -print | sort)
if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
    printf 'No Swift application sources found.\n' >&2
    exit 1
fi

swiftc \
    -module-name ClipVault \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK_PATH" \
    -parse-as-library \
    -framework AppKit \
    -framework SwiftUI \
    -framework Carbon \
    -framework ServiceManagement \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -lsqlite3 \
    "${SOURCE_FILES[@]}" \
    -o "$APP_BUNDLE/Contents/MacOS/ClipVault"

printf 'Built local app bundle: %s\n' "$APP_BUNDLE"
printf 'Build is unsigned. Developer ID signing and notarization are not performed.\n'
