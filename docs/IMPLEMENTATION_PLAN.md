# Native clipboard manager implementation plan

The source of truth is `AGENT.md`, then `REQUIREMENT.md`, then `DESIGN.md`.
`GOAL.md` defines delegation, quality gates, and milestone commits/pushes.
The complete V1 remains the goal; an individual gate is not V1 completion.

## Starting evidence — 2026-09-11

- Repository contains only the four specification files; no existing application or tests.
- Branch: `main`, initially without commits. Configured GitHub remote has no heads.
- Native environment: macOS 26.6.2, Swift 6.3.3, Xcode 26.6.
- The system developer directory selects Command Line Tools. Build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not change the user's global setting.
- No Swift/macOS-specific skill is available in the session catalogue. Use the repository instructions,
  installed SDK, and current primary Apple/Swift documentation.

## Architecture and ownership

- SwiftUI application in `App/`, built as a native macOS 26+ Xcode app.
- Small local Swift package in `Sources/ClipboardCore/`, with feature-oriented subfolders only as needed.
- `Tests/ClipboardCoreTests/` exercises logic and named private pasteboards with synthetic fixtures.
- `NSPasteboard` and window/focus integration stay outside SwiftUI rendering.
- SQLite stores metadata/search and references local payload files. Database and large payload work
  must not block the main actor. No remote services or third-party dependencies are planned.
- The supervising agent plans, integrates, reviews, and accepts gates. Terra handles straightforward
  implementation/validation; Luna Max handles complex native interactions and independent review.
- Concurrent agents own disjoint files. Each significant change receives an independent review,
  fixes, and fresh build/test evidence before acceptance. Only accepted milestones are committed/pushed.

## Gate A — Clipboard core

- [x] Create Swift package, native Xcode application/shared scheme, build instructions and ignores.
- [x] Define content identity, required history metadata, and recent-item deduplication.
- [x] Monitor `NSPasteboard.changeCount` at roughly 400 ms, with cheap unchanged ticks.
- [x] Capture text/URLs into in-memory history; reject unsupported/private transient content safely.
- [x] Centralize clipboard writes and suppress internal writes without suppressing later external copies.
- [x] Connect lifecycle and minimal SwiftUI history display; avoid later UI polish.
- [x] Test hashing, deduplication, metadata, stable snapshots, suppression and lifecycle.
- [x] Independently review; fix findings; build/test and verify a named pasteboard integration.

Publication: inspect/stage accepted files, commit `feat: complete clipboard core`, and push `main`.
The commit and remote history are the authoritative publication receipt.

## Gate B — Persistent history and search

Implementation choices for this gate:

- A `ClipboardHistoryRepository` actor opens SQLite and performs all database work away from the main actor.
  `history(query:filter:limit:)` returns metadata rows without payload data; `item(id:)` hydrates a selected payload.
- `ClipboardItem.payload` may be absent in a metadata row. Restore rejects an unhydrated item without changing
  the pasteboard. Capture values still contain the original representation data.
- Retention uses `lastUsedAt`, preserving all pins in addition to the unpinned limit. Schema/FTS changes are transactional.
- A small main-actor observable controller serializes capture writes, ignores stale search responses, and drains
  pending writes before shutdown. UI rendering never performs SQLite work.
- Debug named-pasteboard runs use an isolated local database. Production storage uses Application Support.
- Lightweight, conservative text classification supplies meaningful Code filtering; no content is executed or rewritten.

- [x] Add SQLite schema migrations and transactional repository operations.
- [x] Persist metadata and text/URL payloads; reopen database without losing history or pin state.
- [x] Enforce defaults of 1,000 unpinned items and 30 days; preserve pinned entries.
- [x] Maintain local text/source/URL/metadata search and type/pinned filters consistently.
- [x] Wire asynchronous persistence and interactive search into the app.
- [x] Test migrations, dedup, retention, pin preservation, restart, deletion and search/filter behavior.
- [x] Independently review, fix, build/test, and verify native restart/search behavior.

Filename capture/search and external blob storage remain in Gate E with file/image support.
Publication: commit `feat: add persistent clipboard history and search` and push `main`.
The commit and remote history are the authoritative publication receipt.

## Gate C — Keyboard workflow

- [ ] Register global `⌘⇧V`, open/close a floating native panel and remember the previous app.
- [ ] Place a 760 × 520 pt panel slightly above center on the active display; focus search and newest result.
- [ ] Implement arrow selection, Return, `⌘Return`, preview, pin/delete bindings, clear search,
  visible-item shortcuts 1–9 and Escape according to `DESIGN.md`.
- [ ] Implement centralized copy-only restoration and reliable close/focus behavior.
- [ ] Test selection/state transitions and verify native shortcut/panel/copy/focus with synthetic content.
- [ ] Independently review, fix, build/test, commit and push accepted Gate C.

## Gate D — Automatic paste

- [ ] Detect Accessibility trust and request it only through relevant user intent.
- [ ] Restore clipboard, close panel, reactivate the remembered app, confirm focus, then issue paste.
- [ ] Avoid synthetic paste without permission; leave copied content available on every failure.
- [ ] Cover stale/missing app, activation failure, focus timeout and permission changes with tests.
- [ ] Verify native paste and copy-only fallback where permission/environment permits.
- [ ] Independently review, fix, build/test, commit and push accepted Gate D.

## Gate E — Full V1 functionality

- [ ] Menu-bar Open/Pause/Clear/Settings/Quit and native ServiceManagement launch at login.
- [ ] Simple General/Privacy/Permissions settings; retention and menu-bar visibility controls.
- [ ] Pins, item deletion, confirmed clear-unpinned/clear-all, pause/resume and source-app presentation.
- [ ] Images, file/folder URLs and practical rich-text representation preservation.
- [ ] Local blob storage without eager row loading; deletion/retention remove unreferenced files.
- [ ] Bundle-ID exclusions and sensitive/transient handling before persistence.
- [ ] Multi-display placement, sleep/wake lifecycle and resilience verification.
- [ ] Review privacy, off-main heavy work, tests and native behavior; fix, build/test, commit and push.

## Gate F — Polish and trusted-tester distribution

- [ ] Native Liquid Glass on shell/controls; readable opaque/material content, semantic colors and SF Symbols.
- [ ] VoiceOver labels, focus visibility, Light/Dark, Increase Contrast, Reduce Transparency and Reduce Motion.
- [ ] Measure idle monitoring, text-history memory, panel/search responsiveness and payload hot paths.
- [ ] Clean Release build and locally verifiable `.app`; optional `.dmg` only if useful.
- [ ] Write build/run/tester instructions with honest signing/notarization and permission expectations.
- [ ] Complete requirement-by-requirement checklist with PASS/PARTIAL/NOT IMPLEMENTED/BLOCKED and evidence.
- [ ] Final fresh independent review of architecture, correctness, privacy, performance, UI, tests and packaging.
- [ ] Fix medium/high findings, rerun full validation, inspect artifacts/diff, commit and push final milestone.

## Verification rules

Builds alone are insufficient. Each gate combines focused unit/integration coverage, clean native builds,
and practical native behavior checks. Never log or include actual user clipboard data in artifacts.
Unperformed hardware or permission-dependent checks remain explicitly unverified; do not infer a pass.
No force pushes, history rewrites, published releases, tags, credential changes or committed build products.
The source documents stay intact. Record evidence and remaining work in `docs/STATUS.md` as gates progress.
