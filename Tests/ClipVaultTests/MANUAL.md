# Actual-Mac integration checklist

The automated core suite does not interact with the live pasteboard, global hotkeys, user login items, or macOS privacy controls. Mark each check only after performing it on a real Mac running macOS 14 or later.

- [ ] Launch ClipVault and confirm its custom clipboard icon appears in the menu bar without a persistent Dock icon or fabricated history entries.
- [ ] Press Option+V, open and dismiss the history panel, and verify the configurable Carbon shortcut unregisters when the app exits.
- [ ] Copy plain text, RTF, a URL, a file URL, and an image from different apps; confirm one local item per new content hash and useful source metadata where macOS provides it.
- [ ] Disable text, image, and URL/file monitoring one at a time; verify each disabled type is ignored while enabled types continue to be captured.
- [ ] Single-click each history item and paste into a compatible destination; confirm the panel closes and original rich-text, image, URL, and file representations remain usable.
- [ ] Save a screenshot into the configured folder; confirm it is ignored while incomplete, captured after the file stabilizes, and copied to the clipboard no more than once when auto-copy is enabled.
- [ ] Select a custom screenshot folder, quit and relaunch, and verify the saved folder bookmark and monitoring behavior.
- [ ] Disable screenshot detection separately from clipboard monitoring and verify saved files are ignored; pause all monitoring, then resume and verify enabled monitors restart.
- [ ] Pause monitoring and verify both clipboard and screenshot capture stop, then resume and verify both restart.
- [ ] Test All, Text, Images, URLs, and Pinned filters, search, arrow-key selection, Enter restore, Escape close, Command+F focus, delete, pin/unpin, menu Clear History, confirmed Clear Unpinned, and confirmed Clear All.
- [ ] Test system, light, and dark appearance; show and hide the menu-bar icon; verify item previews, empty, filtered-empty, and paused states.
- [ ] Test launch-at-login registration and inspect macOS System Settings if approval is required.
- [ ] Exercise a large image, unavailable screenshot folder, denied folder access, and recovery after restoring access.
- [ ] Quit and relaunch; verify local history, pins, and settings persist and image assets remain readable.
