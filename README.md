# ClipVault

ClipVault is a local-first macOS menu-bar clipboard history utility. It stores supported clipboard representations and screenshot assets on the Mac, with SQLite metadata and external files. The app does not use network access or content-bearing logs.

## Requirements

- macOS 14 or later
- Apple silicon build environment
- Swift 6.3.3 and the matching Command Line Tools
- `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` (or set `MACOS_SDK_PATH` to a compatible SDK)

Xcode and `xcodebuild` are not required by the local shell scripts. The app target is also described in `ClipVault.xcodeproj` for Xcode environments.

## Build and test

```sh
Scripts/test.sh
Scripts/build.sh
Scripts/package-dmg.sh
```

`Scripts/test.sh` builds and runs the 18-check offline core regression suite. `Scripts/build.sh` creates `build/ClipVault.app` with its native icon. `Scripts/package-dmg.sh` creates `build/ClipVault.dmg` and reports its local signing state. Local packaging is not a Developer ID release; notarization is not performed.

The scripts intentionally fail if the expected matching SDK is unavailable rather than silently selecting the incompatible active SDK. To use another compatible SDK:

```sh
MACOS_SDK_PATH=/path/to/MacOSX.sdk Scripts/build.sh
```

## Install locally

Run `Scripts/package-dmg.sh`, open `build/ClipVault.dmg`, and copy `ClipVault.app` to Applications. The package is unsigned or ad-hoc signed, not Developer ID signed or notarized. macOS may show a security prompt for locally built software.

## Defaults and settings

- Global history shortcut: Option+V
- History limit: 500 items
- Screenshot folder: Desktop
- Screenshot auto-copy: enabled
- Launch at login: enabled
- Clipboard and screenshot monitoring: enabled

Use the menu-bar icon or Option+V to open history. Clicking a history item restores it to the clipboard and closes the panel. Settings include per-type clipboard monitoring, screenshot detection and auto-copy, screenshot folder, history limit, theme, shortcut, menu-bar icon visibility, launch-at-login, storage usage, and confirmed clearing of unpinned or all history. Folder access may require macOS approval. If launch-at-login cannot be registered, inspect Login Items in System Settings.

## Local data and privacy

History data lives under `~/Library/Application Support/ClipVault/`. The history directory and asset folders use owner-only permissions; SQLite and binary assets are stored with owner-only file permissions. SQLite stores metadata and small UTF-8 representations; image and other binary representations are kept as external assets. Cleanup retains pinned entries and removes unreferenced files at startup. Clipboard content is not sent to a service, and content is not written to diagnostic logs.

Only supported macOS pasteboard flavors are captured: plain text, RTF/HTML, URLs, file URLs, PNG, TIFF, JPEG, GIF, and ICNS. Unsupported-only clipboard states are ignored. Duplicate content is suppressed by a deterministic hash of the supported representations.

## Troubleshooting and verification

If the app cannot monitor a folder, choose it again in Settings and grant access when macOS prompts. Shortcut registration can fail if another app already owns the selected combination; choose Control+Option+V in Settings. Local build or package failures print the compiler or system-tool error directly.

Core behavior is covered by the command-line test runner. Live pasteboard restoration, shortcut delivery, screenshot permissions, login items, menu-bar visibility, and appearance must still be checked using [`Tests/ClipVaultTests/MANUAL.md`](Tests/ClipVaultTests/MANUAL.md) on an actual Mac; these integrations are not claimed as verified by the automated suite.
