#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_PATH="${MACOS_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK_PATH" ]]; then
    printf 'Required macOS 26.5 SDK not found: %s\nSet MACOS_SDK_PATH to a compatible SDK.\n' "$SDK_PATH" >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-tests.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
TEST_BINARY="$TEMP_DIR/ClipVaultCoreTests"
SOURCE_FILES=()
while IFS= read -r source; do
    [[ "$source" == "$ROOT/Sources/ClipVault/App/ClipVaultApp.swift" ]] && continue
    SOURCE_FILES+=("$source")
done < <(find "$ROOT/Sources/ClipVault" -type f -name '*.swift' -print | sort)

swiftc \
    -module-name ClipVaultCoreTests \
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
    "$ROOT/Tests/ClipVaultTests/CoreTestRunner.swift" \
    -o "$TEST_BINARY"
"$TEST_BINARY" "$@"
