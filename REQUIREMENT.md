# macOS Clipboard Manager — REQUIREMENT.md

> Product name: **TBD**  
> Temporary repo name: `macos-clipboard-manager`  
> Platform: **macOS 26 Tahoe+**

## 1. Product

A private, local-first clipboard history manager for macOS.

The app records useful clipboard content, makes it quickly searchable, and lets the user restore or paste older clipboard items into the previously active application.

The project is initially for personal use but should be buildable for trusted friends and suitable for public source code on GitHub later.

---

## 2. Technology

Use the native Apple stack only:

- Swift 6,
- SwiftUI,
- AppKit where SwiftUI is insufficient,
- ApplicationServices/CoreGraphics where required,
- `NSPasteboard`,
- SQLite for local persistence,
- SQLite FTS5 or equivalent local search,
- SF Symbols,
- native macOS 26 Liquid Glass APIs,
- ServiceManagement for launch at login.

No backend is required.

Core functionality must work without a network connection.

---

## 3. V1 Goals

V1 must provide:

- clipboard monitoring,
- clipboard history,
- text and URL capture,
- images,
- copied files/folders,
- local persistence,
- fast search,
- pinning,
- deletion and history clearing,
- global `⌘⇧V` shortcut,
- floating panel,
- keyboard navigation,
- copy again,
- automatic paste when Accessibility permission exists,
- menu-bar access,
- launch at login,
- source-app information,
- app exclusions,
- pause recording,
- duplicate prevention,
- multi-monitor support,
- light/dark/contrast accessibility support.

---

## 4. Not Required for V1

Do not build these unless requirements change:

- iOS/iPadOS version,
- Windows/Linux version,
- web app,
- cloud backend,
- user accounts,
- sync,
- analytics,
- AI features,
- OCR,
- browser extension,
- plugin ecosystem,
- App Store release.

---

## 5. Clipboard Monitoring

Use `NSPasteboard.general`.

Requirements:

- detect changes using `changeCount`,
- avoid busy loops,
- initial polling target: roughly 300–500 ms,
- do nothing expensive when the clipboard has not changed,
- never crash on unsupported pasteboard types,
- prevent the app's own copy/paste operations from creating duplicate history entries.

Supported content:

- plain text,
- URLs,
- rich text where practical,
- images,
- file/folder URLs.

When multiple pasteboard representations exist, keep enough information to restore the clipboard faithfully where practical.

---

## 6. History Item

A history item should support at least:

```text
id
contentHash
primaryType
plain/searchable text
sourceAppName
sourceBundleID
createdAt
lastUsedAt
isPinned
byteSize
payload metadata
payload/blob reference
```

Recommended types:

```text
text
code
url
image
files
richText
other
```

`code` may initially be only a classification of text.

---

## 7. Duplicate Handling

Consecutive identical items should not create repeated rows.

Use a content hash/identity.

When an item is copied again:

- reuse/update the existing recent item where reasonable,
- preserve pinned state,
- update relevant timestamps.

---

## 8. Persistence

Use a local SQLite database.

Recommended defaults:

- maximum unpinned items: `1000`,
- maximum unpinned age: `30 days`,
- pinned items do not expire automatically.

Large image/blob data should be stored in Application Support storage rather than loaded into normal history rows unnecessarily.

Deleting history must also clean unused blob files.

---

## 9. Search

Search must feel immediate.

Search across:

- clipboard text,
- URLs/domains,
- file names,
- source app,
- searchable metadata.

Filters:

```text
All
Text
Code
Links
Images
Files
Pinned
```

Architecture may later support queries such as:

```text
type:code docker
app:terminal ssh
pinned database
```

Advanced query syntax is not required for the first release.

---

## 10. Global Panel

Default shortcut:

```text
⌘ ⇧ V
```

On open:

1. Remember the previous application.
2. Detect the active display.
3. Open the floating panel on that display.
4. Focus search immediately.
5. Select the newest matching item.

The full common workflow must be possible with the keyboard.

---

## 11. Paste Behavior

### Copy only

The user must always be able to put an old item back on the system clipboard.

This must work even without Accessibility permission.

### Auto-paste

When Accessibility permission is available:

1. restore the selected item to `NSPasteboard`,
2. close the panel,
3. reactivate the previous application,
4. wait only as needed for focus,
5. issue the normal paste action,
6. avoid recording this internal write as a new history item.

If auto-paste fails, the restored item must remain on the clipboard so the user can press `⌘V` manually.

---

## 12. Privacy

Clipboard content is sensitive.

V1 rules:

- no clipboard content leaves the Mac,
- no telemetry containing clipboard data,
- do not log clipboard payloads,
- support excluded applications by bundle identifier,
- support pause/resume recording,
- ignore known transient/concealed pasteboard content where appropriate,
- allow clearing one item, all unpinned items, or all history with confirmation.

Never include real user clipboard secrets in tests or debug fixtures.

---

## 13. Menu Bar and Launch at Login

Menu-bar actions should include:

- Open Clipboard,
- Pause/Resume Recording,
- Clear History,
- Settings,
- Quit.

Launch at login should use native macOS APIs.

A permanent Dock icon is not required for normal operation.

---

## 14. Accessibility

Support:

- full keyboard navigation,
- VoiceOver-friendly labels,
- visible focus states,
- Reduce Motion,
- Reduce Transparency,
- Increase Contrast.

Accessibility permission is requested only for functionality that needs it, especially synthetic auto-paste.

The app must remain useful without that permission.

---

## 15. Performance

This is an always-running utility.

Targets:

- negligible idle CPU use,
- low memory use during normal text history,
- no expensive work on every polling tick,
- no synchronous heavy database/image operations on the main actor,
- panel should appear quickly after the global shortcut,
- search should update interactively while typing.

Measure hot paths before adding complexity.

---

## 16. Distribution

### Development / personal use

The app can be built and run locally from Xcode without a paid Apple Developer Program membership.

### Trusted-friend testing

The project should be able to produce a `.app` and optionally a `.dmg` for manual distribution to trusted Mac users.

Without Developer ID signing/notarization, testers may need to manually approve the application through macOS security controls.

### Future public distribution

If downloadable builds are published broadly, prefer:

```text
Release build
→ Developer ID signing
→ Hardened Runtime
→ Apple notarization
→ staple notarization ticket
→ .dmg
→ GitHub Release / website
```

A paid Apple Developer Program membership can be added at that stage.

Do not require App Store distribution.

---

## 17. Repository and Naming

The public product name is not selected yet.

Until a name is properly screened, use neutral internal naming where practical.

Suggested temporary GitHub repository name:

```text
macos-clipboard-manager
```

Avoid publishing releases under a product name that has not been checked for obvious conflicts with existing clipboard applications, GitHub projects, domains, and trademarks.

---

## 18. Delivery Order

Build in this order:

1. Swift/Xcode project skeleton.
2. Clipboard monitoring.
3. In-memory text history.
4. SQLite persistence.
5. Search.
6. Floating panel + `⌘⇧V`.
7. Keyboard navigation.
8. Copy selected item.
9. Auto-paste and focus restoration.
10. Menu bar + launch at login.
11. Pin/delete/clear/pause.
12. Images/files/rich text.
13. App exclusions and privacy hardening.
14. Multi-monitor and sleep/wake testing.
15. Final Liquid Glass polish.
16. Packaging for trusted-friend testing.

Correct clipboard and paste behavior comes before visual polish.
