# Clipboard Manager

Clipboard Manager is a private, local-first macOS clipboard history manager. It
uses Swift 6, SwiftUI, and native macOS frameworks only.

## Full V1 functionality

Gates A–F are implemented and independently reviewed. All 145 tests pass with Swift warnings
treated as errors, and clean Debug and universal Release builds pass. The app is packaged for
trusted testers with native Liquid Glass chrome and readable clipboard content. See the precise
[validation evidence and native-environment limits](docs/STATUS.md).

Build a verified `.app` and ZIP with `Scripts/package-release.sh`. The package supports Apple silicon
and Intel, is locally ad-hoc signed, and is not notarized. Follow the [tester guide](docs/TESTER_GUIDE.md)
for installation, permissions and keyboard checks. [Performance measurements](docs/PERFORMANCE.md)
include 1,000-item history, search, large payloads and native idle CPU/memory.

The bundled app icon uses Apple's native Icon Composer format for macOS 26
appearance modes and Retina sizes. The menu-bar icon uses a monochrome SF Symbol.
See [icon artwork, provenance, and editing instructions](docs/ICON_DESIGN.md).

The app stores accepted text, URLs, practical rich text, images, and ordered file/folder references in local SQLite history at
`~/Library/Application Support/com.example.ClipboardManager/history.sqlite`.
It opens storage asynchronously, keeps normal history rows metadata-only, and
queries SQLite for the visible list. Large payloads use private local blob files and are loaded only when selected. Search includes retained history rather
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
or `→` opens the preview after list navigation or pointer selection, and `Esc` closes the panel
and restores the previously active application when it is still appropriate.
`Return`, double-click, and `⌘1` through `⌘9` restore the chosen item, close the
panel, and request a normal paste into the remembered application when it is
still the active destination and macOS permits input synthesis. `⌘Return`
and preview Copy restore the clipboard without requesting automatic paste.
If paste cannot proceed, the copied item remains available for manual `⌘V`.
A newer clipboard write is respected; the app asks you to choose the item again.

Opening the panel and using copy-only never request Accessibility permission.
Choosing Paste or Enable Accessibility may show the macOS permission prompt.
The app remains useful without this permission. Posting a paste request does
not guarantee that the destination accepts it.

The menu-bar item provides Open Clipboard, Pause/Resume, Clear History, Settings and Quit.
Settings include a configurable shortcut, native launch at login, menu-bar visibility, retention,
recording pause, and excluded bundle identifiers. Hiding the menu icon enables a Dock fallback.
`⌘P` pins or unpins the selection. `⌘Delete` and preview Delete request confirmation; clearing
can retain pins or remove all history. Default retention keeps at most 1,000 unpinned items for
30 days. Concealed/transient content and excluded sources are checked before normal payload reads.
If macOS denies clipboard access, the app shows guidance to enable it in System Settings.

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
--test-storage-directory /tmp/ClipboardManager-GateE-smoke
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
Named-board runs always use copy-only fallback unless an explicit
`--test-paste-target-app-path` identifies the dedicated synthetic native editor.
The target must match its expected bundle identifier and exact application path.
This restriction prevents a smoke test from issuing paste into normal apps.

While paused at a breakpoint in the running app, use Xcode's debug console to
write synthetic text to that named board, then resume so the monitor can poll:

```swift
expr -l Swift -- import AppKit
expr -l Swift -- let board = NSPasteboard(name: NSPasteboard.Name("com.example.ClipboardManager.smoke")); board.clearContents(); board.setString("Gate E smoke item", forType: .string)
```

Within about 0.4 seconds, `Gate E smoke item` should appear in the floating
panel. Use `⌘⇧V` to hide and show the panel, and select the row with `↓` then
press `⌘Return` to verify explicit copy-only restoration on the isolated board.
Return also copies and closes in this run, with fallback guidance on reopening.
Quit normally, relaunch with the same two arguments, and verify that the row
and a matching search result remain. The arguments are absent from Release
builds and no test board is pre-seeded.

After this synthetic smoke test, remove only the exact synthetic directory you
created:

```bash
rm -rf /tmp/ClipboardManager-GateE-smoke
```
