# Implementation status

Full V1 goal: **in progress**. Gates A and B have passed their quality gates; Gates C–F remain.

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| A — Clipboard core | Accepted | 20 tests, clean signed native build, private-board UI smoke and final independent review passed. Git milestone: `feat: complete clipboard core`. |
| B — Persistence/search | Accepted | 38 tests, clean signed native build, independent review, private-board search/filter/restart checks passed. Git milestone: `feat: add persistent clipboard history and search`. |
| C — Keyboard workflow | Not started | Next gate: global shortcut, floating panel, keyboard selection and copy workflow. |
| D — Automatic paste | Not started | Requires accepted Gate C. |
| E — Full V1 | Not started | Requires accepted Gate D. |
| F — Polish/distribution | Not started | Requires accepted Gate E and full final audit. |

## Environment

Verified on 2026-09-11: macOS 26.6.2, Swift 6.3.3, Xcode 26.6.
Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Xcode commands.
The initially empty remote now contains Gate A commit `567a8056cc1c84630f3988702afdf46bb388105b` on `main`;
local and remote hashes were rechecked before Gate B.

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

## Outstanding evidence

Gate A checks used isolated named pasteboards. The real General Clipboard consent alert/System Settings
interaction was not changed or manually exercised; access policy transitions were tested through the
actual boundary with injected policy values. No production clipboard payload was used for verification.

Panel/global shortcut, keyboard actions, auto-paste/Accessibility, full menu/settings,
rich content, exclusions, multiple displays/sleep-wake, final appearance/performance and distribution
remain tracked in `IMPLEMENTATION_PLAN.md` and `REQUIREMENTS_CHECKLIST.md`.
