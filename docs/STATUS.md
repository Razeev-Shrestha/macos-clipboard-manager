# Implementation status

V1 implementation and trusted-tester packaging: **accepted through Gate F**, with the native-environment
limits below. The final milestone uses `release: prepare macos clipboard manager v1` on `main`;
Git history and the checked remote are the publication receipt.

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| A — Clipboard core | Accepted | 20 tests, clean signed native build, private-board UI smoke and final independent review passed. Git milestone: `feat: complete clipboard core`. |
| B — Persistence/search | Accepted | 38 tests, clean signed native build, independent review, private-board search/filter/restart checks passed. Git milestone: `feat: add persistent clipboard history and search`. |
| C — Keyboard workflow | Accepted | Independent review, 59 tests and clean signed build pass. User confirmed normal-build search results and global shortcut close. Native copy/navigation/preview and earlier editor-return checks pass. |
| D — Automatic paste | Accepted | Independent review, 84 tests, clean signed build and strict signature check pass. Native trusted insertion, explicit copy-only and denied-destination fallback pass with synthetic content. |
| E — Full V1 | Accepted | Independent App/Core review, 145 warning-as-error tests, clean signed build, and scoped native rich/privacy/control/restart checks pass. |
| F — Polish/distribution | Accepted | Independent final review, 145 warning-as-error tests, clean Debug/universal Release builds, appearance/performance checks and strict app/ZIP verification pass. |

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
- Published Gate D as `ff6db690f86b899a667a35cf62dface1e55c94fe`; the remote hash matched and the
  worktree was clean before Gate E began.

## Gate E acceptance — 2026-09-12

- Implemented ordered native rich/image/file capture, private external payload storage and schema v2 migration,
  asynchronous enrichment/history controls, settings/privacy policy, login service, menu access and display recovery.
- Independent App and Core review each built or tested the integrated candidate; the Core review passed
  134 warning-as-error tests. All accepted findings were fixed and re-reviewed before the final full run and acceptance.
- Main's integrated signed Debug build passed. The first native run used only named board
  `com.example.ClipboardManager.gate-e-e01`, ignored synthetic storage and its isolated settings suite.
- Native capture produced text, rich text, two images, ordered file/folder references and a resumed fixture.
  Paused content was not replayed; an excluded synthetic source and a concealed second item were both omitted.
- CmdReturn restored exact original representation bytes for rich text, both images and both ordered file references.
  The history and FTS stayed at six rows without internal-write duplicates. Image selection showed the correct
  small and large previews; file names and source metadata were visible.
- Native launch-at-login registration reported Enabled, then unregister reported Disabled. The test leaves login
  disabled. This verifies registration behavior, not an actual subsequent login. Existing Accessibility reads Enabled.
- A temporary CmdOptionShiftY shortcut was recorded and the default restored. Hiding the menu icon left the process
  alive with regular activation policy; native reopening still worked. Menu visibility was restored afterward.
- CmdP pinned the external image; the Pinned filter retained it. A selected rich-text item was deleted. Single-item
  confirmation is being added following review and must be rechecked. Cancelling clear preserved all five remaining
  rows; confirming clear-unpinned retained only the pinned external image and its blob.
- The first run quit normally with exit status zero. SQLite reports schema 2, integrity `ok`, one pinned content row,
  one FTS row and one external blob. Restart and final clear-all checks remain for the next reviewed build.
- Native QA found SQL NULL search text becoming an empty image title; a repository fix and regression pass.
  Accepted review fixes address recorder arming/accessibility, shortcut and action error presentation,
  pointer preview behavior, serialized thumbnail work, payload integrity, policy cancellation and lifecycle delivery.


- Final clean signed Debug build and strict signature verification pass. All **145 warning-as-error
  tests** pass; production, project and test source hashes stayed unchanged during that build.
- Relaunch retained the pinned external image, exclusion settings and default recording state. The image
  title now reads Image; pointer selection followed by Right opens its correct bounded preview, and
  printable input returns to search. A custom shortcut survived another normal quit/restart and the
  panel showed that configured shortcut. The recorder exposes its label/value/help to Accessibility,
  arms on Return, disarms after one recording, and permits CmdQ while still focused but unarmed.
- CmdDelete and preview Delete both show the single-item confirmation. Cancel retains the item;
  confirming a separate synthetic text deletion removes it from results. Final Clear Everything removes
  the pinned image as requested. Both final quits exit zero, application logs are empty, and SQLite
  reports schema 2, integrity `ok`, zero content rows, zero FTS rows and zero blob files.
- The default shortcut and menu visibility were restored; launch at login remains disabled. Native testing
  used only the dedicated named board and synthetic storage. Actual second-display unplug, physical
  sleep/wake and subsequent login remain untested on this one-display interactive environment. Software
  geometry, lifecycle and service-boundary tests cover their deterministic behavior. Direct status-menu
  targeting is limited by the available automation; the native menu structure and delegated action paths
  were inspected, and corresponding Settings/panel actions were exercised.


- The final App review passes, including Objective-C exposure of native menu validation, truthful shortcut
  rollback/hints and storage-ready keyboard/control guards. Retention now prunes cached metadata with the
  same age/count policy after capture, unpin, recopy and policy updates, preserving pins. Aged unpin and
  capture-age eviction regressions pass; successful unpin still reports success when retention evicts it.
- After these final deltas, the full **144-test** warning-as-error run and clean signed Debug build pass.
  Strict signature verification and unchanged build-time source hashes pass. The exact app then captured
  rich text, pinned/unpinned it, displayed the preview and copied the original RTF/plain bytes exactly.
  Internal copy kept one content/FTS row. Confirmed final clearing returned content/FTS/blob counts to zero;
  normal quit exited zero and its log stayed empty.


- Final focused Core review has no medium/high blocker. Cached recopy timestamps now advance before
  pruning, and all mutation cache updates complete inside the FIFO database task before later captures.
  The deterministic recopy regression verifies membership and timestamp parity across age/count pruning.
- Main's final full **145-test** warning-as-error suite, clean signed Debug build, strict signature check,
  and unchanged source-hash check pass. The exact app copied and recopied original rich-text bytes,
  advanced recency and retained exactly one content/FTS row. Final confirmed clearing left zero
  rows/index entries/blobs; integrity is `ok`, the app log is empty, and normal quit exited zero.
- Gate E is accepted with the native-environment limitations recorded above. Publication uses
  `feat: complete v1 clipboard functionality` on `main`; Git history and the checked remote are the receipt.

## Outstanding evidence

Gate A checks used isolated named pasteboards. The real General Clipboard consent alert/System Settings
interaction was not changed or manually exercised; access policy transitions were tested through the
actual boundary with injected policy values. No production clipboard payload was used for verification.

Unavailable display/sleep/login interactions, direct status-menu targeting and VoiceOver spoken
navigation remain explicitly tracked in `REQUIREMENTS_CHECKLIST.md`. Appearance, performance and
local distribution checks are complete. These limits are tester follow-up, not missing implementations.

## Gate F acceptance — 2026-09-12

- Gate E published as `0d4341c29fa9b8d593ce0b90696f82a7fb6be71c`; remote hash matched and the worktree was clean.
- Delegated native appearance/accessibility, isolated performance harness and Release packaging with separate file ownership.
- Main recorded original system settings before appearance QA: Dark/Clear, Increase Contrast off,
  Reduce Transparency off, Reduce Motion off and VoiceOver off. Every temporary change was restored
  through System Settings and read back after QA.
- Native Light/Dark inspection verified readable opaque history and text/image previews, with native
  glass restricted to chrome and controls. Reduce Transparency makes chrome opaque. Increase Contrast
  strengthens row selection and native control boundaries in both appearances. Reduce Motion search
  works; the app uses static presentation without decorative animation or animated panel resizing.
- History rows expose individual accessibility labels, selected state and named actions. AX Pin changed
  the pin state and AX Copy restored the exact synthetic image bytes. Image previews have a descriptive
  label. The shortcut recorder's compact value fits, Return arms recording and Escape cancels.
- VoiceOver's system switch briefly accepted On but reverted Off on two settled attempts. Accessibility
  structure and actions were inspected independently; spoken announcements and VoiceOver cursor/rotor
  navigation remain unverified. No successful spoken check is claimed.
- The final 1,000-row native Debug check measured 0.083% of one core with the expanded panel open and
  0.050% closed over separate 60-second intervals. RSS was 112.02–115.22 MiB open and 113.06–113.08 MiB
  closed. Profiling identified dynamic relative-date text as the original 14.8% open-panel CPU cost;
  static localized copied timestamps removed that work. See PERFORMANCE.md for methods and limits.
- Final search and selected preview showed the expected synthetic result. Observed open/search/preview
  times were 534/465/494 ms including automation, not app-only or physical-key latency. The optimized
  harness measures 1,000 metadata rows, FTS, selected hydration and 1 MiB hash/blob paths separately.
- Final CmdReturn restored the exact selected synthetic text without editor insertion; content and FTS
  stayed at two rows with integrity `ok`. Automatic-paste retries correctly fell back when targeted
  automation captured a destination outside the dedicated editor allowlist. The successful native trusted
  insertion remains the Gate D evidence; no new Gate F insertion is claimed. Copy/focus coordination
  source is unchanged by the visual work. All native test apps quit normally and their logs are empty.
- The benchmark accepts only its fixed synthetic fixture and refuses unknown options, symlinks, unexpected
  file kinds and open SQLite files. Sacrificial guard checks pass. This also prevents a repeat of a test-only
  fixture reset collision encountered during parallel review. Production clipboard/storage were untouched.
- Fresh independent UI and final Core/privacy/concurrency/performance/packaging reviews have no remaining
  medium or high issue. All accepted findings were fixed and re-reviewed. The final clean signed Debug
  build, all 145 warning-as-error tests and a fresh universal Release build pass. All 39 app/project/test
  build-input hashes remained unchanged. The only Xcode warning is skipped AppIntents metadata extraction
  because this app does not depend on AppIntents.
- `Scripts/package-release.sh` produced the `.app`, ZIP, source/build metadata and SHA-256 checksums.
  Both original and ZIP-extracted apps pass strict ad-hoc signature and bundle validation, contain arm64
  and x86_64 slices, and omit all Debug test flags. Release was inspected without launching it against
  the General pasteboard. Packages stay in ignored `build/Distribution/`; no release, tag, credentials
  or generated product is committed. The tester guide explains local approval and permission behavior.

## Native app icon update — 2026-09-12

- Added original clipboard/history artwork and the editable macOS-only
  `Assets/AppIcon.icon` document. Xcode compiles the native appearance variants
  and Retina assets into both configurations. Build 2 retains version 0.1.0 and
  the macOS 26.0 deployment target. The menu-bar SF Symbol explicitly uses
  template rendering.
- Default, Dark, Clear Light/Dark, and Tinted Light/Dark native exports were
  inspected, including 16/32 pixel readability. `NSWorkspace` resolves the
  compiled icon correctly. `Assets.car` contains modern 32–1024 pixel renditions
  and appearance stacks; the generated ICNS fallback contains 16/32/128/256
  pixel representations. See `ICON_DESIGN.md` for the retained artwork, exact
  generation prompt, native editing instructions, and compatibility evidence.
- Clean universal Debug and Release builds pass with unsuppressed Swift
  warnings treated as errors, all 145 tests pass, and strict signatures verify.
  The package validator now requires both icon metadata keys and compiled icon
  resources in the original and extracted app. No clipboard or focus logic was
  changed for the icon update.
- Independent icon/source/build review found no blocker. The original no-icon
  bundle fails the new resource requirements, while build 2 satisfies them.


## UI refresh — 2026-09-12

- Build 3 uses a native titled, resizable floating panel with close, minimize,
  and screen-sized zoom controls. Full-size content lets the Liquid Glass shell
  extend behind the titlebar while AppKit's safe area protects the controls.
  Search, recording controls, and footer surround a separate opaque reading area.
- Filter selection moves over 180 ms; Settings tabs crossfade with a small offset.
  Both honor the animation preference and Reduce Motion. Reduce Transparency uses
  opaque chrome; increased contrast strengthens selection boundaries. Environment
  guards were inspected; system accessibility preferences were not changed in this run.
- Shortcut hints use separate keycaps in a four-column, two-row layout. Native
  screenshots verify readable Light and Dark appearances at default size, expanded
  image preview, and the minimum 620 × 420 usable content size. Native zoom expanded
  to the visible screen and restored its previous size; minimization removed the
  window, and reopening retained the usable panel.
- Settings opens from the panel gear, menu, or Command-comma. It starts at the top
  of General, rather than scrolling to the shortcut recorder. General includes
  System/Light/Dark appearance, animation, startup, menu visibility, history count,
  history age, and global shortcut controls. Privacy and Permissions remain available.
  Appearance changes were checked live; retention and animation choices survived a
  normal restart. Test preferences were restored to System, animations on, 30 days,
  recording active, and menu visibility on. Production preferences were untouched.
- Native keyboard QA exercised Down, Tab, Space to pause recording, Return to
  resume, Tab/Return to open Settings, and arrow keys to change Settings tabs.
  Explicit focus handling prevents these controls from triggering preview or paste.
- An isolated named pasteboard and synthetic database were used for all clipboard
  QA. Paused content was not replayed after resuming. Copy restored original rich-text
  representations exactly; automatic paste inserted the selected synthetic text into
  the dedicated probe editor and restored its active/key/first-responder state. Red
  close also returned focus to that editor. The database kept three rows, with integrity
  `ok`, and the test apps quit normally. No production clipboard payload was logged.
- Independent review found keyboard-focus and native Dock-reopen issues; both were
  fixed and reviewed. The final full warning-as-error suite passes all 155 tests,
  including 13 native window tests. Debug and universal Release builds pass; original
  and ZIP-extracted Release apps pass strict signature and bundle validation. The only
  Xcode warning remains skipped AppIntents metadata extraction.
- The display name and packaged bundle are now Clipboard Manager / Clipboard Manager.app;
  the executable and bundle identifier remain stable. Menu-bar artwork resolves the
  same compiled Icon Composer asset as Finder and Spotlight. Its resolved image was
  rendered and inspected from the installed bundle. Direct status-menu automation was
  not needed to change the image source.
- Final output: `build/Distribution/ClipboardManager-Release-20260912T113748Z-KTVJ01/`.
  The signed app was installed at `~/Applications/Clipboard Manager.app` and its binary
  hash matched the verified package. Generated packages, fixtures, and test logs remain
  ignored. Source changes are left in the working tree; no commit or push was requested.

## Menu-bar icon and Settings navigation — 2026-09-13

- Version 0.1.0, build 4 replaces the full-color status tile with a transparent
  AppKit template glyph using the original clipboard, three snippets, and offset
  sheet motif. Native 20/40 px renders verify monochrome pixels and transparent
  corners; Finder and Spotlight keep the original Icon Composer app artwork.
- Normal macOS application menus appear while Clipboard, Settings, or Help is
  presented, including minimized windows. The status menu now includes Help.
  Settings and local Help both provide an accessible, keyboard-usable back button.
  Settings retains arrow-key section navigation without the extra picker focus
  rectangle. Changing settings preserves the visible application menus.
- Back navigation carries the previous external paste destination. A scoped
  workspace observer tracks newer external activations while Settings/Help is
  open or minimized; own and terminated applications cannot replace the target.
  Activation-policy updates do not activate the app or interrupt pending paste.
- Native isolated QA verified app-menu Settings and Help, Command-Comma, Help
  content and keyboard Back, initial Settings position, clean tab appearance,
  arrow navigation, settings changes, and Settings → Clipboard → Return pasting
  synthetic rich text into the dedicated editor with active/key/responder focus.
  CUA's simulated cross-app focus did not produce corresponding NSWorkspace
  activation notifications, so it cannot certify the latest-external-app-switch
  case. That path has independent source review and controller fallback tests.
  Temporary metadata-only tracing was removed before Release packaging.
- All 158 tests pass with Swift warnings treated as errors, including 16 native
  panel tests. Debug and universal Release builds pass; original and extracted
  Release apps pass strict signatures, architecture, icon, and bundle checks.
  The only Xcode warning remains skipped AppIntents metadata extraction.
- Final package: `build/Distribution/ClipboardManager-Release-20260913T045553Z-T0Gko8/`.
  The verified app was installed and reopened at `/Applications/Clipboard Manager.app`;
  the running executable path and installed binary hash match the package. The
  previous bundle is retained in `build/Reinstall-backup-d53n04w2/`. Reinstallation
  does not replace the production history database or preferences. All validation
  fixtures used named synthetic pasteboards and isolated storage.
