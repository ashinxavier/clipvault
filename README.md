# ClipVault

ClipVault is a local-first clipboard history app for macOS. Find and restore recent copies from the menu bar or with a keyboard shortcut. Clipboard content and screenshot assets stay on your Mac; ClipVault uses no account, cloud sync, analytics, or network service.

## Features

- Capture supported text, rich text, URLs, file references, and images.
- Search and filter history, pin useful items, and restore the original clipboard content.
- Watch a screenshot folder, wait for new images to finish writing, and optionally copy them to the clipboard.
- Pause and resume monitoring, choose a history limit, and manage local storage.
- Use a floating, keyboard-friendly history panel without a persistent Dock window.

## Install a local build

To create and install a local package:

```sh
bash Scripts/package-dmg.sh
```

Open `build/ClipVault.dmg`, then copy `ClipVault.app` to Applications. The package is ad-hoc signed when Apple's `codesign` tool is available, but it is not Developer ID signed or notarized. macOS may show a first-launch security warning.

## Get started

1. Launch ClipVault. Its clipboard icon appears in the menu bar.
2. Copy text, a URL, a file reference, or an image as usual.
3. Open history from the menu bar or press **Option + V**.
4. Search or filter the list, then select an item to restore it to the clipboard.
5. Open **Settings** from the menu or the history panel to adjust capture and privacy preferences.

### Default settings

- Shortcut: **Option + V** (alternative: **Control + Option + V**)
- History limit: **500 items**
- Screenshot folder: **Desktop**
- Clipboard and screenshot monitoring: **On**
- Screenshot auto-copy: **On**
- Launch at login: **On**

The Settings page groups controls into General, Clipboard, Screenshots, Storage, and Privacy. It includes shortcut and appearance choices, per-type monitoring, screenshot folder selection, storage cleanup, and monitoring pause/resume.

## Local data and privacy

ClipVault keeps its database and assets here:

```text
~/Library/Application Support/ClipVault/
```

SQLite stores history metadata; image and other binary content is stored as local files. The app applies restrictive permissions to its data directory and files, retains pinned items during routine cleanup, and does not log clipboard contents. Screenshot-folder access and launch-at-login behavior are subject to macOS settings and approvals.

## Build and test from source

### Requirements

- macOS 14 or later
- Apple silicon (the current build scripts target `arm64`)
- Apple Command Line Tools with Swift 6.3.3
- The macOS 26.5 SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` by default

The shell scripts use `swiftc`; the Xcode GUI is not required. An Xcode project is included for development in Xcode. To use another compatible SDK, set `MACOS_SDK_PATH`:

```sh
MACOS_SDK_PATH=/path/to/MacOSX.sdk bash Scripts/test.sh
MACOS_SDK_PATH=/path/to/MacOSX.sdk bash Scripts/build.sh
```

### Commands

```sh
bash Scripts/test.sh       # Compile and run the 21-check core suite
bash Scripts/build.sh      # Build build/ClipVault.app
bash Scripts/package-dmg.sh # Build and package build/ClipVault.dmg
```

The automated suite covers core normalization, persistence, deduplication, monitoring, screenshot stability, and menu-state behavior. It does not exercise live macOS pasteboard access, global shortcut delivery, login items, folder permissions, or the visible menu UI.

For those device-specific checks, follow the [actual-Mac integration checklist](Tests/ClipVaultTests/MANUAL.md). Do not treat a passing command-line suite as verification of those macOS integrations.

## Troubleshooting

- **Shortcut does not open history:** another app may own the shortcut. Choose **Control + Option + V** in Settings.
- **Screenshot folder is unavailable:** select the folder again in Settings and approve access if macOS asks.
- **Launch at login does not take effect:** review ClipVault under **System Settings → General → Login Items**.
- **Build reports a missing SDK:** install the expected Command Line Tools SDK or set `MACOS_SDK_PATH` to a compatible macOS SDK.

## Project layout

- `Sources/ClipVault/` contains the app, UI, clipboard and screenshot monitors, and local persistence.
- `Tests/ClipVaultTests/CoreTestRunner.swift` contains the offline regression suite.
- `Tests/ClipVaultTests/MANUAL.md` contains real-Mac integration checks.
- `Scripts/` contains the build, test, and DMG packaging commands.

## License

ClipVault is released under the MIT License. See [LICENSE](LICENSE).
