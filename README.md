# Clipboard Manager

Clipboard Manager is a private, local-first macOS clipboard history manager. It
uses Swift 6, SwiftUI, and native macOS frameworks only.

## Gate A status

This initial scaffold provides a macOS app shell and a local Swift package for
`ClipboardCore`. Gate A currently monitors text and URLs with `NSPasteboard`
change counts and shows the in-memory history. The app lifecycle starts and
stops the monitor; SwiftUI renders the observable history snapshot.

There is no menu bar, global shortcut, floating panel, persistence, automatic
paste, or Accessibility request yet. If macOS denies clipboard access, the app
shows guidance to enable Clipboard access in System Settings; it never requests
Accessibility permission.

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

### Debug-only isolated pasteboard smoke test

For a UI smoke test without reading your general clipboard, add this Debug
launch argument in the shared scheme:

```text
--test-pasteboard com.example.ClipboardManager.smoke
```

This argument is compiled only in Debug and makes the monitor use the named,
isolated pasteboard. While paused at a breakpoint in the running app, use
Xcode's debug console to write synthetic text to that board, then resume the
app so its monitor can poll:

```swift
expr -l Swift -- import AppKit
expr -l Swift -- let board = NSPasteboard(name: NSPasteboard.Name("com.example.ClipboardManager.smoke")); board.clearContents(); board.setString("Gate A smoke item", forType: .string)
```

Within about 0.4 seconds, `Gate A smoke item` should appear in the window. The
argument is absent from Release builds and the test board is never pre-seeded.
An empty, missing, or general-pasteboard name stops the Debug app before it can
fall back to the general pasteboard.
