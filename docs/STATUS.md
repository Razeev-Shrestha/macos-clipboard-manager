# Implementation status

Full V1 goal: **in progress**. Gates A–D have passed their quality gates.
Full V1 functionality and distribution remain Gates E–F.

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| A — Clipboard core | Accepted | 20 tests, clean signed native build, private-board UI smoke and final independent review passed. Git milestone: `feat: complete clipboard core`. |
| B — Persistence/search | Accepted | 38 tests, clean signed native build, independent review, private-board search/filter/restart checks passed. Git milestone: `feat: add persistent clipboard history and search`. |
| C — Keyboard workflow | Accepted | Independent review, 59 tests and clean signed build pass. User confirmed normal-build search results and global shortcut close. Native copy/navigation/preview and earlier editor-return checks pass. |
| D — Automatic paste | Accepted | Independent review, 84 tests, clean signed build and strict signature check pass. Native trusted insertion, explicit copy-only and denied-destination fallback pass with synthetic content. |
| E — Full V1 | Not started | Gate D accepted; menu/settings, rich payloads, privacy and reliability are next. |
| F — Polish/distribution | Not started | Requires accepted Gate E and full final audit. |

## Environment

Verified on 2026-09-11: macOS 26.6.2, Swift 6.3.3, Xcode 26.6.
Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Xcode commands.
The initially empty remote now contains Gate A commit `567a8056cc1c84630f3988702afdf46bb388105b` on `main`;
local and remote hashes were rechecked before Gate B. Gate B commit
`6a803d279ca590fcf805871493967e9c34e4ba4f` is also pushed to `main`; remote and clean worktree were rechecked before Gate C.

## Decisions

- Preserve the provided product/architecture requirements; neutral internal name `ClipboardManager`.
- SwiftUI native application with local `ClipboardCore` package; no third-party dependencies.
- Initial validation uses synthetic fixtures and private named pasteboards, never the user's clipboard.
- macOS pasteboard consent must be surfaced; restoration will use `.currentHostOnly` to prevent
  Universal Clipboard propagation of restored history. See `NATIVE_API_NOTES.md` for sources.
- Native UI, permissions, multiple displays and sleep/wake checks will be recorded when their gates arrive.

## Gate A acceptance — 2026-09-11

- Final independent review passed after fixes for initial denied access, timer cleanup and empty restore preflight.
- Main's final full test run passed all **20 XCTest tests** with Swift warnings treated as errors:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --parallel -Xswiftc -warnings-as-errors`.
- Main's clean Xcode Debug build passed with `-destination 'platform=macOS,arch=arm64'`,
  `-derivedDataPath build/DerivedData`, and `CODE_SIGNING_ALLOWED=YES`.
- `codesign --verify --strict` passed for the resulting native `.app`; minimum OS is 26.0.
- Xcode used local ad-hoc signing with no paid developer team. Review found only native Apple/Swift dependencies.
- Native Debug application smoke check used `--test-pasteboard` with a dedicated synthetic board:
  text appeared via the live timer; a repeated copy kept one row; a URL became the newest row;
  a concealed fixture was omitted. The SwiftUI window was visually inspected. Normal quit exited cleanly.
- The smoke fixture was released after validation. No real user clipboard payload was used as a fixture.
- The final clean app was relaunched after the access/lifecycle changes; live capture and normal quit passed.
- Empty restore was reproduced as a failing test before its preflight fix; the final 20-test suite includes
  verification that both the previous content and pasteboard version remain intact.

## Git milestone

Branch: `main`. Gate A commit: `567a8056cc1c84630f3988702afdf46bb388105b`,
`feat: complete clipboard core`, pushed and verified on GitHub. No generated build artifacts are included.

The repository config enables signing with an SSH public key but omits `gpg.format`. Use the per-command
override `git -c gpg.format=ssh commit ...` to honor signing without changing credentials or global/repository settings.

## Gate B acceptance — 2026-09-11

- Native SQLite actor provides transactional schema creation, deduplication, retention, pin/delete/clear operations,
  FTS5 search and explicit payload hydration. List/search rows omit payload bytes.
- The app opens storage asynchronously, serializes accepted captures, displays durable query results, rejects stale
  query generations, stops recording after a storage error, and drains accepted writes before normal quit.
- Code classification uses a bounded conservative heuristic; original clipboard representations are preserved.
- Final independent review found no high- or medium-severity blocker. Separate reviewer builds and all 38 tests passed.
- Main's final full run passed all **38 XCTest tests** with warnings treated as errors:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --parallel -Xswiftc -warnings-as-errors`.
- Main's clean, signed Xcode Debug build and `codesign --verify --strict` passed using the same commands as Gate A.
- Tests cover migration failure rollback, newer-version rejection, restart hydration, exact retention boundaries,
  newest-item retention, pin preservation, stable ordering, NUL text, literal prefix search, type filters, FTS update/delete,
  write rollback, durable controller shutdown, sticky storage failure, and rejection of metadata-only clipboard restore.
- Final native app validation used a private named pasteboard and a dedicated synthetic database under ignored `build/`.
  Text, code and URL captures appeared through live polling; Text/Code/Links filters and text/domain prefix search worked.
  Three rows survived normal quit/relaunch. Recopying a persisted item reused one row and moved it to the top.
- Native QA exposed a retained scroll offset after filter changes. The fix was rechecked visually: the newest result
  remains visible after switching filters and clearing search. Filtered empty-state guidance also passed.
- Both native quits exited successfully. SQLite reported schema version 1 and `integrity_check = ok`, with three
  content rows and three FTS rows. The new directory/database had permissions 0700/0600.
- Gate B publication uses `feat: add persistent clipboard history and search` on `main`; Git and remote history record
  the commit receipt. Generated build artifacts and synthetic databases are excluded from Git.

Review follow-ups: adversarial delayed-search/startup-shutdown interleavings have source review but no deterministic
barrier-based test. Migration coverage will expand when a second schema exists. The Debug test-directory exclusion
is lexical; validation used a newly created directory, not a symlink. External blob storage/cleanup remains Gate E.

## Gate C acceptance — 2026-09-12

- Added native Carbon global shortcut registration, a reusable floating panel, previous-app capture and guarded
  focus restoration, selection transitions, text preview, copy-only actions and durable recency updates.
  Automatic paste remains Gate D; pin/delete controls remain Gate E.
- Independent source review found no high- or medium-severity blocker. Main and an independent reviewer passed
  all **59 XCTest tests**, a clean signed Debug build with Swift warnings treated as errors, and strict
  code-signature verification on 2026-09-11. The normal build was checked again on 2026-09-12 after diagnostic removal: all 59 tests passed,
  the clean signed build succeeded, and strict code-signature verification passed. The only Xcode tool warning
  was skipped AppIntents metadata extraction because this app has no AppIntents dependency.
- Review fixes cover pre-responder key routing, native modifier flags, cancelled copies, atomic query/filter
  provenance, normal printable search input, and numbered shortcuts ordered by the displayed viewport.
- Native validation uses twelve synthetic history rows, a private named pasteboard, an isolated database and
  a separate synthetic editor app. No production clipboard payload is read or used as a fixture.
- Arrow selection, Space/Right preview, spaced search, CmdK, pointer selection and double-click passed.
  Return, CmdReturn and a numbered copy from a lower viewport restored the exact expected private-board text.
  Copies preserved twelve history rows and updated recency; normal quit/restart and SQLite integrity passed.
- Reopening resets the viewport to the newest selected row even when its identity is unchanged. Search focus
  requests follow the key-window notification, coalesce by generation and do not clear an already focused field.
  The close path cooperatively yields activation to the captured app before requesting its activation.
- Through the synthetic probe's cooperative native reopen action, the app became active before any window
  inspection, accepted complete search input without a click, and restored the actual prior foreground app
  after Escape and CmdReturn. Typing then reached the original editor without another click.
- The compact floating panel measures 760 × 520 pt and is centered horizontally about 32 pt above the visible
  frame's center on the connected display. Expanded preview measures 1040 × 640 pt. Multiple displays remain E.
- Targeted window automation did not deliver the global Carbon shortcut. A physical keyboard check on
  2026-09-12, with temporary metadata-only diagnostics, recorded valid hotkey events, MainActor callback
  dispatch, panel opening/activation, and a later visible-panel toggle to closed.
- The user confirmed that physical CmdShiftV opened Clipboard Manager with search focused. The typed query
  `probe` was present in the field and correctly displayed No Matching Clipboard Items: no fixture matches it.
  Clearing search with CmdK and entering `keyboard` displayed all twelve synthetic rows. This report does not
  establish a search-focus defect; no speculative focus or shortcut implementation change was made.
- Temporary logging contains only lifecycle/registration metadata, never clipboard payloads or user text.
  All diagnostic source/wiring has been removed and independently reviewed with no blocker. The diagnostic app
  and probe were normally quit and the metadata log stream stopped. The synthetic database still reports
  integrity `ok`, twelve rows and twelve FTS rows. The normal build and a fresh targeted probe are now running
  with the same isolated board/storage for the final physical check.
- The user confirmed the normal build returns results for `keyboard` and closes with physical CmdShiftV.
  This completes the physical global-shortcut evidence after diagnostic removal. Earlier native Escape and
  copy checks establish editor-focus restoration on the same functional code; the independent cleanup review
  confirmed those paths did not change. The final automation-only activation attempt was inconclusive because
  its focused-window state differed from the desktop foreground process; it is not counted as another pass.
- Gate C is accepted on the scoped evidence above. Physical shortcut and search behavior are established by
  the user; native copy/navigation/preview and editor-return evidence comes from the recorded independent
  system checks. Multi-display behavior, automatic paste and final accessibility coverage remain their later gates.
- Published `feat: complete keyboard clipboard workflow` as `2e8e246442208aeee1abaeb87a6c29bdb92c69fb`
  on `main`; the remote hash was read back and matched. The worktree was clean before D began.
  The test app and probe were normally quit; SQLite still reports integrity `ok` and twelve content/FTS rows.
  The full A–F objective remains incomplete.

## Gate D acceptance — 2026-09-12

- Added a centralized copy/close/focus/paste coordinator. It snapshots the destination before hydration,
  validates the exact restore receipt, checks current Accessibility and event-post access, and posts
  Command-V only to the same live foreground application. Delivery is bounded and cancellable.
- Return, numbered actions and double-click request paste; CmdReturn and preview Copy remain explicit
  copy-only actions. Copy-only never requests Accessibility. Fallback guidance survives reopening, and
  a completed or cancelled action releases the UI for the next action.
- Main's full warning-as-error suite passes all **84 tests**. Coverage includes permission changes,
  target termination/switching, bounded focus waits, expected-close versus dismissal, stale completion,
  clipboard replacement and receipt ownership. Tests replace event posting and never target user apps.
- Native fallback used a named synthetic board and isolated database with two fixtures. Return with no
  permitted synthetic destination restored the exact selected fixture and closed the panel. Reopening
  preserved fallback guidance; search and a subsequent CmdReturn worked. No duplicate history appeared:
  normal quit exited successfully, SQLite integrity is `ok`, and both content and FTS contain two rows.
- Independent review has no remaining blockers. Review fixes use semantic `NSRunningApplication.isEqual`
  identity and recheck the exact clipboard receipt after permission preflight, immediately before posting.
  A regression test replaces the clipboard during preflight and verifies that no paste is posted.
- The final clean signed Debug build and strict signature verification pass. Source hashes confirm that the
  tested production files did not change during the build. The only Xcode warning is the expected skipped
  AppIntents metadata extraction because this app has no AppIntents dependency.
- The user explicitly authorized ClipboardManager's Accessibility permission and continuing the remaining
  goal unattended. The exact reviewed build was added through System Settings; its switch read back On.
  Reopening the panel refreshed permission availability and removed the Enable Accessibility guidance.
- The dedicated native paste probe reads only the named synthetic board. Debug synthesis requires its
  explicit bundle ID and exact app path. A cooperative editor-to-panel interaction followed by Return
  inserted exactly `Synthetic Gate D first paste item` into the editor. Its standard paste handler recorded
  one insertion from the named board at change count 5. This verifies real native posting and insertion,
  beyond the coordinator's deliberately limited paste-requested outcome.
- CmdReturn with permission enabled restored the second fixture and closed the panel while the editor
  retained the first fixture and its paste count stayed at one. This establishes explicit copy-only behavior
  even when synthesis is permitted. No production clipboard payload was read or used as a fixture.
- Targeted automation's focus context can differ from the desktop foreground process between calls.
  A later numbered action captured a destination outside the synthetic allowlist and correctly fell back
  to copying; it is not counted as a second successful native insertion. Numbered paste routing is covered
  by model tests. No product focus change was made solely to accommodate this automation behavior.
- Both test applications quit normally with exit status zero. SQLite integrity remains `ok`, with two
  content rows and two FTS rows after copying and pasting. The final production source matches the
  clean signed build. Gate D is accepted on the scoped evidence above; E and F remain incomplete.
- Publication uses `feat: add automatic paste and focus restoration` on `main`; Git history and the
  checked remote commit are the publication receipt. Generated fixtures and build artifacts stay ignored.

## Outstanding evidence

Gate A checks used isolated named pasteboards. The real General Clipboard consent alert/System Settings
interaction was not changed or manually exercised; access policy transitions were tested through the
actual boundary with injected policy values. No production clipboard payload was used for verification.

Full menu/settings, rich content, exclusions, multiple displays/sleep-wake, final appearance/performance and distribution
remain tracked in `IMPLEMENTATION_PLAN.md` and `REQUIREMENTS_CHECKLIST.md`.
