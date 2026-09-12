# Native API decisions

Verified against the installed macOS 26.5 SDK, Xcode 26.6, and primary documentation on 2026-09-11.

## Clipboard access and monitoring

`NSPasteboard.accessBehavior` is available from macOS 15.4. The SDK describes General pasteboard
programmatic access as asking by default; other named pasteboards default to allowing access.
Once a programmatic read triggers an alert, users can manage Ask / Always Allow / Always Deny in
System Settings. Background clipboard history therefore depends on system-managed clipboard consent.
No documented clipboard usage-description plist key or entitlement was found.

Monitor `changeCount` before reading payloads and verify it again after the read. An unstable
snapshot is discarded. Checking the count does not bypass clipboard privacy. A denied state must
be surfaced without repeatedly attempting denied payload reads.

An app-originated write must not suppress an unrelated external write that races it. The adapter
uses the exact change count returned by `prepareForNewContents`, writes each representation, and
requires that same count after writing. The monitor rechecks it before suppression. It must never
label an arbitrary post-write count as its own. This ownership check avoids rereading the payload
for copy-only behavior; a real named-pasteboard round-trip test covers the AppKit contract.
Subsequent external copies are captured even when their payload matches an internal restore.

The app restores history with `prepareForNewContents(with: [.currentHostOnly])` to honor its local-only
privacy requirement. Apple documents that this option prevents Universal Clipboard propagation.
It persists until the next prepare/clear by a writer. Ordinary receiving applications can still paste.

Sources: [Apple AppKit updates](https://developer.apple.com/documentation/updates/appkit),
[NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard),
[access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum),
[preparing new contents](https://developer.apple.com/documentation/appkit/nspasteboard/preparefornewcontents(with:)),
[contents options](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions).

## Swift concurrency

Keep AppKit pasteboard interaction on the main actor. The SDK marks Timer's block `@Sendable`;
use an explicit main-actor hop when necessary. Pass immutable, Sendable snapshot data to heavy
hashing/persistence work rather than sharing AppKit objects across actors.

Sources: [Timer](https://developer.apple.com/documentation/foundation/timer),
[Swift actor-isolated-call diagnostic](https://docs.swift.org/latest/documentation/diagnostics/actor-isolated-call/).

## Local SQLite

The installed SDK supplies the SQLite3 module, library, and FTS5 API. Runtime SQLite 3.51.0
reports `ENABLE_FTS5=1`; a temporary in-memory FTS5 table can be created successfully.
Native SQLite is sufficient; no external package is needed for the persistence milestone.

Source: [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html).

## Global shortcut and panel

The installed HIToolbox `CarbonEvents.h` exposes `RegisterEventHotKey` for a virtual key and modifiers,
including exclusive registration and an explicit conflict error. Registration/unregistration are not thread-safe,
so this app owns both on the main actor. This is a native shortcut registration, not a keyboard event tap.
No Accessibility or Input Monitoring request is introduced for the shortcut.

The utility uses an activating `NSPanel` with a reusable SwiftUI hosting view. It captures the previous application
before activation and returns focus only while the clipboard app still owns the interaction; switching to another
app dismisses the panel without forcing focus back. Geometry is clamped to the chosen screen's visible frame.

macOS activation is a request that depends on the current interaction context. When returning control from the
active clipboard app, the guarded close path first calls `NSApp.yieldActivation(to:)`, then asks the captured
`NSRunningApplication` to activate. Yielding supplies the cooperative handoff context; it does not itself activate
the other app or prove that its editor has focus. Native foreground and typing checks remain necessary.

Panel keyboard handling sits in the window's `sendEvent(_:)` override before the focused text editor consumes events.
Unhandled events continue through AppKit. Modifier matching considers Command/Shift/Option/Control separately from
Caps Lock, numeric-pad and function flags so normal arrow events remain usable. Actual shortcut, field-editor and
focus behavior still requires native interaction checks; unit geometry/state tests do not establish those results.

Search focus follows the panel's key-window notification. SwiftUI's `FocusState` removes field focus when set to false,
so repeated opening requests must not clear a field that already accepts input. Pending requests are coalesced and
only the latest may request focus after a key window exists. Desktop activation and first-input behavior still require
native validation beyond a targeted window tool's reported focus label.

Sources: installed Xcode SDK `Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEvents.h`,
[NSPanel](https://developer.apple.com/documentation/appkit/nspanel),
[window event dispatch](https://developer.apple.com/documentation/appkit/nswindow/sendevent(_:)),
[SwiftUI focus state](https://developer.apple.com/documentation/swiftui/focusstate),
[cooperative application activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation),
[application activation](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)).
