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

Implementation choices for this gate:

- Native system helpers own global shortcut registration, the floating `NSPanel`, display placement and focus restoration.
  Prefer permission-independent hotkey registration; Accessibility and synthetic paste remain Gate D.
- SwiftUI owns readable search/results/preview content. A small value type owns selection transitions across result changes.
- Copy hydrates one persisted item, restores through the existing monitor, and updates recency without creating a new entry.
  Cancelled or closed UI actions must not write after an asynchronous lookup returns.
- `Return` and numbered actions use copy-only behavior in this gate and say Copy in the UI. Gate D supplies automatic paste.
  Pin/delete actions follow in Gate E. These are staged delivery boundaries, not changes to the final keyboard specification.
- Search text entry (including spaces/caret movement) must work normally. Preview keys apply when result selection has focus.
- Native validation uses a private pasteboard, isolated database and a synthetic companion window for focus checks.

- [x] Register global `⌘⇧V`, open/close a floating native panel and remember the previous app.
- [x] Place a 760 × 520 pt panel slightly above center on the active display; focus search and newest result.
- [x] Implement arrow selection, Return/`⌘Return` copy, preview, clear search,
  numbered copy shortcuts 1–9 and Escape; complete paste bindings in D and pin/delete bindings in E.
- [x] Implement centralized copy-only restoration and reliable close/focus behavior.
- [x] Test selection/state transitions and verify native shortcut/panel/copy/focus with synthetic content.
- [x] Independently review, fix, build/test, commit and push accepted Gate C.

Acceptance: independent review, all 59 warning-as-error tests, a clean signed build, and strict
signature verification pass. Native search/copy/preview/navigation, single-display placement, and
Escape/copy return-to-editor checks pass with synthetic content. The user confirmed normal-build
physical shortcut opening/search and closing. See `STATUS.md` for the precise native evidence and limits.
Publication: commit `feat: complete keyboard clipboard workflow` and push `main`.

## Gate D — Automatic paste

Implementation choices for this gate:

- Keep the copy → close → activate → focus check → paste flow in a small native coordinator.
  Snapshot the destination before asynchronous payload loading and preserve existing cancellation guards.
- Distinguish the intended close after a successful copy from user dismissal so the paste cannot cancel itself.
  Reopening, shutdown, a superseding action or a deliberate switch to another app cancels pending delivery.
- Check current Accessibility trust and event-post access before synthesis. Request trust only from relevant
  user intent; copy-only never prompts. Use a short bounded focus wait and revalidate immediately before posting.
- Post Command-V to the validated destination PID. The API has no delivery acknowledgement: call the outcome
  paste requested, retain the copied content for manual fallback, and verify insertion separately in native QA.
- A dedicated native test editor handles standard paste using only an isolated named board. Unit tests inject
  permission/activation/posting boundaries and deterministic suspension points; they never post to user apps.

- [x] Detect Accessibility trust and request it only through relevant user intent.
- [x] Restore clipboard, close panel, reactivate the remembered app, confirm focus, then issue paste.
- [x] Avoid synthetic paste without permission; leave copied content available on every failure.
- [x] Connect Return and numbered actions to paste, retaining `⌘Return` as copy-only per `DESIGN.md`.
- [x] Cover stale/missing app, activation failure, focus timeout and permission changes with tests.
- [x] Verify native paste and copy-only fallback where permission/environment permits.
- [x] Independently review, fix, build/test, commit and push accepted Gate D.

Independent review has no remaining blockers after semantic application-identity and final clipboard-receipt
fixes. All 84 warning-as-error tests, the clean signed Debug build and strict signature verification pass.
Native Return inserted the exact synthetic fixture into the dedicated editor after the user-authorized
Accessibility grant. CmdReturn copied another fixture without insertion; denied-destination fallback and
duplicate suppression passed. See STATUS.md for the targeted-automation activation limits.
Publication: commit `feat: add automatic paste and focus restoration` and push `main`.

## Gate E — Full V1 functionality

Implementation boundaries for this gate:

- Preserve ordered native pasteboard items and practical text/URL/RTF/image/file representations.
  Existing single-item payloads keep their Codable representation and content identity. Check privacy
  markers and excluded sources across every pasteboard item before reading normal payload bytes.
- Keep large payloads in private local blob storage, migrate existing SQLite history safely, and hydrate
  only a selected item. Hashing, rich-text enrichment and blob I/O must stay outside main-actor UI work.
  Delete/clear/retention clean unreferenced payloads while preserving pins and transaction consistency.
- Persist simple settings independently of clipboard contents. Debug validation uses isolated defaults
  alongside its named board/database. Serialize history controls with accepted capture writes; pausing
  and sleep/wake must not replay content copied while recording was suspended.
- SwiftUI provides menu-bar actions, General/Privacy/Permissions settings and explicit destructive-clear
  confirmation. Native helpers own configurable Carbon registration, login service status and lifecycle.
  Preserve the working paste coordinator and panel keyboard/focus contracts.
- Delegate capture/models, persistence, and runtime controls with separate file ownership. Integrate the
  App UI after their API contracts stabilize, then use fresh independent review and final native QA.

- [x] Menu-bar Open/Pause/Clear/Settings/Quit and native ServiceManagement launch at login.
- [x] Simple General/Privacy/Permissions settings; retention and menu-bar visibility controls.
- [x] Pins, item deletion, `⌘P`/`⌘Delete` bindings, confirmed clear-unpinned/clear-all, pause/resume and source-app presentation.
- [x] Images, file/folder URLs and practical rich-text representation preservation.
- [x] Local blob storage without eager row loading; deletion/retention remove unreferenced files.
- [x] Bundle-ID exclusions and sensitive/transient handling before persistence.
- [x] Multi-display placement, sleep/wake lifecycle and resilience verification.
- [x] Review privacy, off-main heavy work, tests and native behavior; fix, build/test, commit and push.

Acceptance: independent App/Core review, 145 warning-as-error tests, clean signed Debug build,
strict signature verification and native rich/privacy/control/restart/recopy checks pass. Available
geometry/lifecycle tests pass; physical display, sleep and subsequent-login limits remain explicit in STATUS.md.
Publication: `feat: complete v1 clipboard functionality` on `main`.

## Gate F — Polish and trusted-tester distribution

Implementation boundaries for this gate:

- Add native macOS 26 glass only around chrome/controls. Keep clipboard text, images and dense metadata
  on opaque semantic surfaces. Respect system contrast/transparency/motion settings and expose each
  row as an individually labeled Accessibility element with working actions.
- Preserve the accepted capture, persistence, keyboard, focus and paste contracts. Main owns native UI
  interaction and restores all temporarily changed appearance/accessibility preferences afterward.
- Measure optimized synthetic core paths separately from the actual Debug app's idle memory/CPU and
  interaction timing. Record hardware, setup, counts and automation overhead; do not invent targets.
- Produce a reproducible clean, locally signed Release app and ZIP without paid credentials or publication.
  Inspect signatures, supported architectures, bundle metadata and the extracted artifact. Never launch
  Release with Debug isolation flags, which are absent in Release builds.
- Use fresh independent final review, update every requirement row with evidence/limits, and publish only
  the accepted source milestone. Build products and synthetic data stay under ignored `build/`.

- [x] Native Liquid Glass on shell/controls; readable opaque content, semantic colors and SF Symbols.
- [x] VoiceOver labels/actions, focus visibility, Light/Dark, Increase Contrast, Reduce Transparency and Reduce Motion; record the spoken-VoiceOver environment limitation.
- [x] Measure idle monitoring, text-history memory, panel/search responsiveness and payload hot paths.
- [x] Clean Release build and locally verifiable `.app` plus ZIP; DMG is unnecessary for this scope.
- [x] Write build/run/tester instructions with honest signing/notarization and permission expectations.
- [x] Complete requirement-by-requirement checklist with PASS/PARTIAL/NOT IMPLEMENTED/BLOCKED and evidence.
- [x] Final fresh independent review of architecture, correctness, privacy, performance, UI, tests and packaging.
- [x] Fix medium/high findings, rerun full validation, inspect artifacts/diff and prepare the final milestone.

Acceptance: 145 warning-as-error tests, clean Debug and universal Release builds, strict original/extracted
package checks, independent reviews and scoped native appearance/performance checks pass. Static row
timestamps reduce 1,000-row open-panel idle CPU from 14.8% to 0.083% of one core. Native hardware,
VoiceOver speech and automation-focus limits remain explicit in STATUS.md and the requirement checklist.
Publication: `release: prepare macos clipboard manager v1` on `main`; Git history and the checked remote
are the final commit/push receipt.

## Verification rules

Builds alone are insufficient. Each gate combines focused unit/integration coverage, clean native builds,
and practical native behavior checks. Never log or include actual user clipboard data in artifacts.
Unperformed hardware or permission-dependent checks remain explicitly unverified; do not infer a pass.
No force pushes, history rewrites, published releases, tags, credential changes or committed build products.
The source documents stay intact. Record evidence and remaining work in `docs/STATUS.md` as gates progress.
