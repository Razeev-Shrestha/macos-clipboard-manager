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

## Automatic paste — Gate D

The native coordinator captures the previous application instance and PID before asynchronous payload loading.
The instance matters because a PID can be reused. Closing the panel clears its remembered target, so the paste
operation retains its own snapshot and revalidates that the same live application is active and frontmost.
Cooperative activation is still best-effort; delivery uses a short bounded, cancellation-aware focus wait.
Compare `NSRunningApplication` objects with `isEqual`, as the SDK requires, rather than Swift wrapper
reference identity or PID alone. If an unrelated app becomes frontmost during the wait, cancel delivery;
do not wait for the original destination to return after a deliberate app switch.

`AXIsProcessTrustedWithOptions` reports current trust. Its optional prompt is asynchronous and does not change
that immediate result. Opening the panel and explicit copy-only actions never request trust. Paste intent or an
explicit Enable action may request it; missing permission falls back to copying. The installed SDK separately
exposes `CGPreflightPostEventAccess` for event-synthesis access, which is checked without an extra prompt.

The intended event is ordinary Command-V, posted to the validated destination PID after final target, permission
and clipboard-version checks. `CGEventPostToPid` returns `void`: posting cannot confirm that the destination
inserted content. Report a paste request honestly and verify insertion separately with a synthetic native editor.
Keep the copied contents on fallback, except that a subsequent external clipboard write must be respected rather
than overwritten. Only the exact change count from the successful restore may establish ownership.

For native QA, the editor's standard paste action reads only the named synthetic board. A Debug named-board
run permits synthesis only to its explicitly configured synthetic editor bundle ID and exact app URL. Without
that target configuration, the run remains copy-only. Tests replace posting, permission and focus boundaries;
they never issue synthetic input to user applications.

Sources: installed macOS SDK `CoreGraphics/CGEvent.h` and `HIServices/AXUIElement.h`,
[Accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions),
[event-post access](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()),
[frontmost application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication),
[process identity](https://developer.apple.com/documentation/appkit/nsrunningapplication/processidentifier),
[PID-targeted event posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)).

## Settings, login and display lifecycle — Gate E

Use `SMAppService.mainApp` for launch at login. Registration may report an already registered service or
user denial, so the UI must refresh the native status instead of treating a saved preference as proof that
the service is enabled. Loading preferences must not register the service automatically. A pending approval
state needs to remain visible even when the registration call throws.

SwiftUI `MenuBarExtra` supports an insertion binding, including removal by the user. Apple also documents
automatic termination for a utility that has only a menu-bar scene when its extra is removed. Hiding the icon
therefore requires a verified, reachable application lifecycle and Dock fallback; changing a preference alone
does not establish that behavior.

Observe `NSApplication.didChangeScreenParametersNotification` to recover an already visible panel after
display configuration changes. The notification arrives on the main actor. Repositioning must not activate a
hidden panel or replace the application captured for focus restoration. Workspace sleep/wake notifications
separately suspend capture and establish a fresh change-count baseline on wake.

Sources: [main application login service](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp),
[service registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()),
[approval status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval),
[menu-bar scenes](https://developer.apple.com/documentation/swiftui/menubarextra),
[display configuration notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification).

## Bounded image previews — Gate E

Decode only the selected image preview, outside the main actor. ImageIO thumbnail creation needs an explicit
`kCGImageSourceThumbnailMaxPixelSize`; without it Apple warns that a thumbnail can be as large as its source.
The current preview target is at most 768 pixels per dimension. Cancellation and selected-item identity must
prevent a previous decode from appearing for a newly selected row. Decoding failure is an item-local preview
error, not a reason to stop recording or hide the history row.

Sources: [ImageIO thumbnail creation](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)),
[thumbnail pixel limit](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize).

### Menu validation

Apple documents that `NSMenu` auto-enables items by default and that setting an item's
`isEnabled` alone has no effect in that mode. The menu target now implements
`NSMenuItemValidation` to compute Clear availability from current storage state whenever
AppKit validates the menu. This avoids a stale availability snapshot.

- [NSMenu.autoenablesItems](https://developer.apple.com/documentation/appkit/nsmenu/autoenablesitems)
- [NSMenuItem.isEnabled](https://developer.apple.com/documentation/appkit/nsmenuitem/isenabled)
- [NSMenuItemValidation.validateMenuItem](https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:))

## Native glass and accessibility — Gate F

Use `GlassEffectContainer` to coordinate native glass chrome and controls. History and preview
surfaces remain opaque semantic backgrounds so clipboard content stays readable. When
`accessibilityReduceTransparency` is enabled, use an opaque chrome fallback. Native
`colorSchemeContrast` drives stronger selection boundaries; Light/Dark colors remain semantic.

Rows expose one labeled accessibility element with selection and named Copy, Paste, Pin/Unpin
and Delete actions. The shortcut recorder exposes a short value and separate instructions.
The app adds no decorative animation and resizes the panel with `animate: false`, including
when Reduce Motion is enabled. DESIGN.md's fade/scale is a recommended feel, not a required effect.

Sources: [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer),
[Reduce Transparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency),
[accessible controls](https://developer.apple.com/documentation/swiftui/accessible-controls).
