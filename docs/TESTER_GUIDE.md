# Clipboard Manager trusted tester guide

This guide is for the locally packaged `Clipboard Manager.app`. It is a native
macOS 26 Tahoe application that keeps clipboard history in local Application
Support storage. The app has no server or telemetry dependency.

## Before you start

- Use macOS 26 or later.
- The packaged app is universal for Apple silicon (`arm64`) and Intel
  (`x86_64`) when built with the default packaging command.
- Use a copy of the ZIP and keep the accompanying `SHA256SUMS.txt` and
  `BUILD-METADATA.txt` files with it. The metadata records the exact source
  revision, dirty state, SDK, architectures, and signing mode.
- This package is locally ad-hoc signed. It is not Developer ID signed,
  notarized, or suitable for public distribution.

## Build and run from a checkout

Install Xcode with the macOS 26 SDK, then run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/package-release.sh
```

The command runs Swift tests with `-warnings-as-errors`, builds a fresh Release
product, signs it ad hoc, verifies the bundle, app icon resources, and signature, checks the
requested architectures, extracts the ZIP again for inspection, and writes all
artifacts below a new directory in `build/Distribution/`. It does not launch
the app. Set `PACKAGE_ARCHS=arm64` or `PACKAGE_ARCHS=x86_64` only when testing
one architecture explicitly.

To run the packaged app, extract the ZIP and open the resulting
`Clipboard Manager.app` in Finder. The app normally remains available from the
menu bar; the default panel shortcut is **Command-Shift-V**. The menu bar menu
also has **Open Clipboard**, **Pause/Resume Recording**, **Clear Unpinned
History**, **Settings**, **Clipboard Manager Help**, and **Quit Clipboard Manager**.
The status icon is a transparent monochrome clipboard. Opening a window also
shows the normal macOS app menus; closing all windows returns to the menu-bar
utility (unless the menu icon is hidden).

Open **Settings** with **Command-Comma**. Use **← Clipboard** to return to
history, preserving the previous paste destination. The Settings section picker
should show its selected segment without an extra blue rectangle around the
entire control, and Left/Right arrows should still change sections. Open
**Help > Clipboard Manager Help** for keyboard and privacy guidance.

If macOS warns that the app is from an unidentified developer, first confirm
that the ZIP and checksum came from the expected tester build. After trying to
open the app, use **System Settings > Privacy & Security > Open Anyway**, then
confirm the app-specific prompt. Do not disable Gatekeeper, lower the global
security setting, or use an unknown copy. Apple describes this manual exception
for apps that are not notarized in [Open apps safely on your Mac](https://support.apple.com/en-us/102445).

## Keyboard and panel checks

1. Copy a few ordinary text, URL, rich-text, image, and file items in another
   app. Open Clipboard Manager with **Command-Shift-V** and confirm the newest
   item is selected and the search field accepts typing.
2. Use **Up/Down** to change selection, **Return** to copy and request an
   automatic paste, **Command-Return** for copy-only, **Command-1** through
   **Command-9** for a visible row, **Space** or **Right Arrow** for preview,
   **Command-K** to clear search, and **Escape** to close and return to the
   previous app. Double-clicking a row requests paste as well.
3. In **Settings > General > Global shortcut**, click the recorder and press a
   replacement shortcut. Restore **Command-Shift-V** when finished. If the
   selected combination is already registered, the app reports the conflict
   and keeps the last working shortcut; use the menu bar or Dock to recover.
4. Pin and delete a row with the row actions or **Command-P** and
   **Command-Delete**. Use **Clear Unpinned** only after confirming whether
   pinned rows should remain.

## Clipboard access, copy, and automatic paste

The first background read of the General pasteboard may trigger a macOS
clipboard access alert. Allow it when testing capture. If access is denied,
the app stays usable but shows that clipboard history is unavailable; change
the app's pasteboard access choice in the macOS privacy settings when it is
listed, then relaunch. Apple documents the per-app General pasteboard states
in [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum).

Copy-only actions always restore the selected item to the clipboard and do not
need Accessibility permission. A paste-intent action copies first, then closes
the panel and attempts a normal **Command-V** in the app that was active before
the panel opened. The result is a request to paste; the app cannot claim that a
destination inserted the content merely because the native event was posted.
If the destination, focus, clipboard ownership, or permissions change, the
item remains copied so it can be pasted manually.

Automatic paste requires both Accessibility trust and macOS event-post access.
Use **Settings > Permissions > Enable Accessibility** only when you are ready
to test that behavior; opening the panel and copy-only actions do not request
it. Approve Clipboard Manager in **System Settings > Privacy & Security >
Accessibility**. Apple explains this permission and how to turn it on or off
in [Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac).
The app does not use an event tap or request Input Monitoring for its global
shortcut.

For a manual paste check, focus a simple editor, copy a known test value, open
Clipboard Manager, select that value, and press **Return**. Confirm the editor
receives it through its ordinary paste command. Then press **Command-Return**
on another item and confirm that the panel closes with the item available on
the clipboard but no automatic insertion. Never use a password, token, or
other sensitive value as a test fixture.

## Privacy, exclusions, and local storage

- **Settings > Privacy > Pause clipboard recording** stops new capture while
  leaving existing history available.
- Add the exact source application's bundle identifier under **Excluded Apps**
  to prevent future capture from that app. Concealed, transient, and
  auto-generated pasteboard markers are excluded automatically.
- **Clear Unpinned History** retains pinned rows; **Clear Everything** removes
  all local history. Confirm the destructive dialog deliberately.
- Production history is stored under
  `~/Library/Application Support/com.example.ClipboardManager/`, including
  `history.sqlite` and the local payload directory. Large payload bytes are
  loaded only when an item is selected for preview or copy. The app does not
  upload clipboard contents.

To test privacy behavior, pause recording, copy a value, resume, add a source
bundle ID to the exclusion list, copy from that source, and verify it does not
appear. Remove the exclusion before continuing unrelated tests. Do not inspect
or paste real private clipboard data into bug reports.

## Launch at login

In **Settings > General**, use **Launch at login** and read the adjacent native
status. The app uses macOS Login Items and reports when approval is still
required. To disable it, turn the toggle off and confirm the status is
**Disabled**. You can also review the system state in **System Settings >
General > Login Items & Extensions**. Apple documents adding and removing
login items in [Change Login Items & Extensions settings on Mac](https://support.apple.com/guide/mac-help/mtusr003/mac).

Hiding the menu bar icon leaves the app reachable from the Dock when the
regular activation policy is needed. Restore the icon after testing so later
testers can open the panel without the shortcut.

## Reporting a result

Include the macOS version, Mac architecture, package metadata filename, and a
short sequence of user actions. Record whether clipboard access and
Accessibility were allowed, whether the target app changed during an action,
and whether the result was **copied only** or **paste requested**. Do not
include clipboard payloads, screenshots containing sensitive content, or
private application names unless the report is specifically about that app.
