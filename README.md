# Clipboard Manager

Clipboard Manager is a private, local-first macOS clipboard history manager. It
uses Swift 6, SwiftUI, and native macOS frameworks only.

## Gate C — keyboard workflow

Gate C is complete and independently reviewed, with 59 passing tests and a clean signed build.
Native app handoff, search, copy, and return-to-editor checks pass with synthetic content. The
physical shortcut opens and closes the panel; see [validation evidence](docs/STATUS.md).

The app now stores accepted text and URL captures in local SQLite history at
`~/Library/Application Support/com.example.ClipboardManager/history.sqlite`.
It opens storage asynchronously, keeps normal history rows metadata-only, and
queries SQLite for the visible list. Search includes retained history rather
than an in-memory subset; the UI provides All, Text, Code, Links, Images,
Files, and Pinned filters.

Accepted captures are written serially. The visible list updates only after a
write is durable, and normal quit stops monitoring, flushes queued writes, then
closes the database. If local storage cannot be opened or a write/query fails,
recording stops and the UI shows a generic storage error; it does not claim the
failed capture was saved.

The app now opens in a reusable floating utility panel and registers `⌘⇧V` to
show or hide it. The panel opens with search focused and the newest visible item
selected; reopening the app from the Dock also shows it. If another application
already owns `⌘⇧V`, the panel remains available from the Dock and explains the
shortcut conflict.

`↑` and `↓` select visible results, `⌘K` clears and refocuses search, `Space`
or `→` opens the text preview after list navigation, and `Esc` closes the panel
and restores the previously active application when it is still appropriate.
`Return`, `⌘Return`, double-click, and `⌘1` through `⌘9` all restore the chosen
item to the clipboard and close only after a successful restore. They are
accurately labeled **Copy** in this stage: Gate C does not auto-paste, request
Accessibility permission, or synthesize input.

There is still no menu bar, pin/delete/clear UI, automatic paste, or
Accessibility request. Images and files have filter placeholders but are not
yet captured by the Gate A monitor. If macOS denies clipboard access, the app
shows guidance to enable Clipboard access in System Settings.

`ClipboardCore` lives in `Sources/ClipboardCore`; its tests live in
`Tests/ClipboardCoreTests`. The Xcode app target links and imports that local
package through a small lifecycle controller.

## Development

This project requires Xcode 26.6 or later with the macOS 26 SDK. The system
Command Line Tools may remain selected; select Xcode only for individual build
commands:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ClipboardManager.xcodeproj \
  -scheme ClipboardManager \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Run the package test suite:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Open `ClipboardManager.xcodeproj` in Xcode and choose the shared
`ClipboardManager` scheme to build or run the app shell.

### Debug-only isolated persistence smoke test

For a UI smoke test without reading your general clipboard or touching the
production database, add these Debug launch arguments in the shared scheme:

```text
--test-pasteboard com.example.ClipboardManager.smoke
--test-storage-directory /tmp/ClipboardManager-GateC-smoke
```

Build the Debug app first:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ClipboardManager.xcodeproj \
  -scheme ClipboardManager \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=YES build
```

The named board uses a stable private temporary store when no storage directory
is supplied. `--test-storage-directory` must be absolute and is accepted only
with a non-general `--test-pasteboard`; malformed test flags terminate the
Debug app before it can open the general pasteboard or production store.

While paused at a breakpoint in the running app, use Xcode's debug console to
write synthetic text to that named board, then resume so the monitor can poll:

```swift
expr -l Swift -- import AppKit
expr -l Swift -- let board = NSPasteboard(name: NSPasteboard.Name("com.example.ClipboardManager.smoke")); board.clearContents(); board.setString("Gate C smoke item", forType: .string)
```

Within about 0.4 seconds, `Gate C smoke item` should appear in the floating
panel. Use `⌘⇧V` to hide and show the panel, and select the row with `↓` then
press `Return` to verify copy-only restoration on the isolated board.
Quit normally, relaunch with the same two arguments, and verify that the row
and a matching search result remain. The arguments are absent from Release
builds and no test board is pre-seeded.

After this synthetic smoke test, remove only the exact synthetic directory you
created:

```bash
rm -rf /tmp/ClipboardManager-GateC-smoke
```
