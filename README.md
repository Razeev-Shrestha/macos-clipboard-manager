# Clipboard Manager

A private, local-first clipboard history manager for macOS, built with Swift 6, SwiftUI and native
macOS frameworks only. No accounts, no network, no tracking. Your history stays on your Mac.

[![Latest release](https://img.shields.io/github/v/release/Razeev-Shrestha/macos-clipboard-manager?label=release)](https://github.com/Razeev-Shrestha/macos-clipboard-manager/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
![Apple silicon and Intel](https://img.shields.io/badge/arch-Apple%20silicon%20%7C%20Intel-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

**Contents:**
[Download](#download) ·
[Features](#features) ·
[Keyboard shortcuts](#keyboard-shortcuts) ·
[Permissions](#permissions) ·
[Privacy and security](#privacy-and-security) ·
[Build from source](#build-from-source) ·
[Releasing](#releasing) ·
[Project layout](#project-layout) ·
[Documentation](#documentation)

---

## Download

### **[⬇ Download Clipboard Manager (DMG)](https://github.com/Razeev-Shrestha/macos-clipboard-manager/releases/latest/download/ClipboardManager.dmg)**

Requires **macOS 26** or later. Universal app for Apple silicon and Intel. [All releases](https://github.com/Razeev-Shrestha/macos-clipboard-manager/releases).

1. Open `ClipboardManager.dmg` and drag **Clipboard Manager** to **Applications**.
2. Launch it. The release is code-signed but not notarized, so macOS first shows a
   "could not verify" warning. Go to **System Settings › Privacy & Security**, scroll to
   **Security** and click **Open Anyway**.
3. Press **`⌘⇧V`** to open your clipboard history.
4. *(Optional)* For automatic paste, allow Clipboard Manager in
   **System Settings › Privacy & Security › Accessibility**.

To verify the download, compare `shasum -a 256 ClipboardManager.dmg` with the
`ClipboardManager.dmg.sha256` file attached to the release.

## Features

**Capture and history**
- Records text, links, code, rich text, images, and files/folders (including multi-file copies).
- Saves history in a local SQLite database. Large items are stored separately and loaded only when you open them.
- Pin important items. Pinned items are never removed by retention.
- Retention defaults to 1,000 unpinned items for up to 30 days. Both limits are configurable.
- Pause recording indefinitely, or for **15 minutes** / **1 hour** with automatic resume, even after sleep or a relaunch.

**Find and paste**
- A floating panel opens with **`⌘⇧V`** (configurable). Search is focused and the newest item is selected.
- Full-text search across all retained history, with **All · Text · Code · Links · Images · Files · Pinned** filters.
- Paste into the app you came from, copy only, or **paste as plain text** without formatting.
- Preview pane with character/word/line counts, **Open Link** (web links only) and **Reveal in Finder** for files.
- Rows show the source app's icon, a colour-coded type label and a relative time ("5 min ago").

**Menu bar and settings**
- Menu bar item: Open Clipboard, Pause/Resume (including timed pauses), Clear History, Settings, Help, Quit.
- Settings cover: global shortcut, launch at login, menu bar icon (hiding it falls back to the Dock), retention,
  appearance, animations, excluded apps (pick them from Applications), sensitive-content filtering and
  Universal Clipboard sharing.
- Native Liquid Glass design that respects Light/Dark Mode, Reduce Transparency, Increase Contrast and Reduce Motion.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘⇧V` | Show or hide the clipboard panel (configurable) |
| `↑` `↓` | Move the selection |
| `Return` / double-click | Paste the selected item into the previous app |
| `⌥Return` | Paste as plain text (no formatting) |
| `⌘Return` | Copy to the clipboard without pasting |
| `⌘1` … `⌘9` | Paste the 1st–9th visible item |
| `Space` or `→` | Toggle the preview |
| `⌘P` | Pin or unpin |
| `⌘Delete` | Delete (asks for confirmation) |
| `⌘K` | Clear and focus search |
| `⌘,` | Settings |
| `Esc` | Close the panel and return to the previous app |

Right-click any row for Paste, Paste as Plain Text, Copy, Pin and Delete.

## Permissions

| Permission | Needed for | Without it |
| --- | --- | --- |
| **Clipboard access** (macOS prompt) | Reading new copies | The app explains how to enable it in System Settings |
| **Accessibility** | Automatic paste (`Return`, `⌘1`–`⌘9`) | Items are copied, and you press `⌘V` yourself |

Opening the panel and copy-only never ask for Accessibility. Choosing **Paste** or
**Enable Accessibility** may show the macOS prompt. After installing a build with a different signature,
re-enable the app under Accessibility once.

## Privacy and security

- **Local only.** No network access, no analytics, no accounts. Clipboard contents are never logged.
- **Sensitive content is skipped.** Content flagged as concealed or transient (for example by password
  managers) is never recorded. Neither is anything from apps you exclude. Text that looks like a private
  key, access token, API key (AWS, GitHub, GitLab, Slack, Stripe, OpenAI/Anthropic, Google), JWT or payment
  card number is skipped too. Turn the last check off in Settings › Privacy › Sensitive content.
- **Deleted means deleted.** SQLite `secure_delete` and FTS5 `secure-delete` overwrite removed history
  instead of leaving it recoverable in free pages or search-index segments.
- **Private storage.** The history folder is owner-only (`0700`) and its files are `0600`. A symbolic-link
  folder is refused, and the folder is excluded from Time Machine and Spotlight.
- **Bounded captures.** Items over 64 MB are not recorded, and search indexes at most 200,000 characters
  per item.
- **Universal Clipboard is opt-in.** Items pasted from history are written for this Mac only, unless you
  turn on Settings › Privacy › **Share pasted items with my other devices**. History never syncs.

History is stored at `~/Library/Application Support/com.example.ClipboardManager/`.

**Known limitation:** the source app is taken to be the frontmost app when a copy is noticed. So excluding
an app is best-effort for background tools (such as `pbcopy`) that copy without the
`org.nspasteboard.source` marker.

## Build from source

**Requirements:** Xcode 26.6 or later with the macOS 26 SDK. Prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if the Command Line Tools are selected.

```sh
# Run the test suite (187 tests)
swift test -Xswiftc -warnings-as-errors

# Build and run the app
xcodebuild -project ClipboardManager.xcodeproj -scheme ClipboardManager \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Clipboard Manager.app"
```

Or open `ClipboardManager.xcodeproj` in Xcode and run the shared **ClipboardManager** scheme.

### Signing

Builds are ad-hoc signed unless you add your team. Copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM`. A team-signed build keeps the
Accessibility permission across rebuilds. See **[docs/SIGNING.md](docs/SIGNING.md)** for Apple Development,
Developer ID and notarization.

### Package a DMG

```sh
Scripts/package-release.sh                              # ad-hoc
SIGNING_MODE=development Scripts/package-release.sh     # signed with your team
SIGNING_MODE=developer-id NOTARY_PROFILE=<profile> \
  REQUIRE_NOTARIZATION=1 Scripts/package-release.sh     # Developer ID + notarized
```

The script runs the tests and builds a universal Release app. It verifies the signature, architectures and
icon resources in the app, the ZIP and the DMG. Output goes to `build/Distribution/<run>/`, with checksums
and build metadata.

<details>
<summary><b>Debug-only isolated smoke test</b> (never touches your real clipboard or history)</summary>

Debug builds accept launch arguments that switch to a private named pasteboard and a separate store:

```text
--test-pasteboard com.example.ClipboardManager.smoke
--test-storage-directory /tmp/ClipboardManager-smoke
```

- `--test-storage-directory` must be absolute and requires a non-general `--test-pasteboard`. Malformed
  flags stop the app before it opens the general pasteboard or the real store.
- These runs only copy and never auto-paste, unless `--test-paste-target-app-path` names the dedicated
  synthetic probe app.
- The flags are compiled out of Release builds, and the packaging script checks that.

To add a synthetic item, pause in Xcode and run:

```swift
expr -l Swift -- import AppKit
expr -l Swift -- let board = NSPasteboard(name: NSPasteboard.Name("com.example.ClipboardManager.smoke")); board.clearContents(); board.setString("Smoke item", forType: .string)
```

The item appears within about 0.4 seconds. Afterwards, remove only the directory you created:
`rm -rf /tmp/ClipboardManager-smoke`.

</details>

## Releasing

Releases are built locally, so the published DMG carries the team signature:

```sh
SIGNING_MODE=development Scripts/package-release.sh      # or developer-id
cp build/Distribution/<run>/ClipboardManager-Release-*.dmg ClipboardManager.dmg
shasum -a 256 ClipboardManager.dmg > ClipboardManager.dmg.sha256
git tag -a vX.Y.Z -m "Clipboard Manager vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z ClipboardManager.dmg ClipboardManager.dmg.sha256 --verify-tag \
  --title "Clipboard Manager vX.Y.Z" --latest
```

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project first. The download link always
serves the latest release's `ClipboardManager.dmg`. Pushing a `v*` tag also starts GitHub Actions, which
never replaces a DMG already attached to the release; if none is attached, it publishes an ad-hoc build.

## Project layout

```text
App/                     SwiftUI/AppKit app: panel, settings, menu bar, app delegate
Sources/ClipboardCore/   Clipboard monitoring, history, search, paste coordination, settings
  Persistence/           SQLite repository and blob storage
  System/                Panel window, global shortcut, auto-paste, launch at login
Tests/ClipboardCoreTests XCTest suite for ClipboardCore
Config/                  Signing xcconfig (+ gitignored local overrides)
Scripts/                 Release packaging and performance measurement
Assets/                  App icon (Icon Composer) and source artwork
docs/                    Design, status, signing, performance and tester docs
```

## Documentation

| Document | Contents |
| --- | --- |
| [docs/SIGNING.md](docs/SIGNING.md) | Signing modes, Developer ID, notarization, CI secrets |
| [docs/TESTER_GUIDE.md](docs/TESTER_GUIDE.md) | Installation, permissions and keyboard checks |
| [docs/STATUS.md](docs/STATUS.md) | Validation evidence and native-environment limits |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | 1,000-item history, search, large payloads, idle CPU/memory |
| [docs/ICON_DESIGN.md](docs/ICON_DESIGN.md) | Icon artwork, provenance and editing |
| [REQUIREMENT.md](REQUIREMENT.md) · [DESIGN.md](DESIGN.md) · [AGENT.md](AGENT.md) | Product requirements, design system, contributor rules |
