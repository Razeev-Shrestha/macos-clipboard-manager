# V1 requirements and acceptance evidence

This checklist preserves the full scope of `REQUIREMENT.md` and `DESIGN.md`.
Statuses are **PASS**, **PARTIAL**, **NOT IMPLEMENTED**, or **BLOCKED**.
PASS requires evidence for the entire row; tests for one part do not prove the rest.
Passing core rows describe the verified Gate A/B behavior. Full V1 remains incomplete, and every
row must be re-audited against the final application before completion.

| ID | Requirement | Gate | Status | Evidence or missing work |
| --- | --- | --- | --- | --- |
| R01 | Native Swift 6, SwiftUI, macOS 26+ application; only necessary AppKit; offline core | A–F | PASS | Native Xcode app/local Swift package builds; no third-party or network dependencies. Re-audit as features grow. |
| R02 | `NSPasteboard.general`, changeCount, 300–500 ms polling, cheap unchanged ticks, unsupported types safe | A | PASS | Production general-board wiring, 400 ms monitor, unit tests and private-board native timer smoke. Real system consent dialog untested. |
| R03 | In-memory clipboard history, plain text and URL capture | A | PASS | Native app smoke shows text/URL rows; capture tests use real named boards. |
| R04 | Required history fields: identity/hash/type/text/source/name/bundle/times/pin/size/metadata/payload reference | A–E | PASS | Immutable Sendable/Codable models contain these fields; actual blob storage remains R24. |
| R05 | Consecutive and recent duplicate reuse, preserve pin/identity, update timestamps | A–B | PASS | In-memory and SQLite dedup/pin/identity/timestamp tests pass; native duplicate capture after restart reused one row. |
| R06 | Internal clipboard writes do not create history entries; later external copies still work | A–D | PARTIAL | Core race/suppression tests and native panel copy checks pass without duplicate rows. Auto-paste path awaits D. |
| R07 | Local SQLite persistence and migrations; restart recovery | B | PASS | Actor repository, transactional schema creation, future-version rejection/migration rollback tests, native quit/relaunch recovery pass. |
| R08 | Transactional writes and consistent local search index | B | PASS | SQLite transactions and FTS5 triggers; update/delete/retention/search and failed-write rollback tests pass. |
| R09 | Retain at most 1,000 unpinned items / 30 days by default; pins never expire normally | B | PASS | Defaults defined; injected-policy tests verify exact age boundary, newest-count retention, unpin pruning and pin preservation. |
| R10 | Interactive search of text, URLs/domains, filenames, source app and metadata | B–E | PARTIAL | Safe prefix FTS searches retained text, URLs/domains, source names/bundle IDs and type metadata. Native interactive search passes; filenames await file capture in E. |
| R11 | All/Text/Code/Links/Images/Files/Pinned filters | B–E | PARTIAL | All seven repository filters are tested and in the UI; native Text/Code/Links checks pass. Image/file capture and pin controls await E. |
| R12 | Global `⌘⇧V` toggles floating panel | C | PASS | Metadata trace verified Carbon delivery; user confirmed normal-build shortcut opening/search and shortcut close after diagnostic removal. |
| R13 | Open remembers previous app, chooses active display, focuses search, selects newest result | C | PARTIAL | Native cooperative reopening focuses search; Escape/copy restore the actual prior foreground app and editor typing. Single-display placement and newest-row reopening pass. User confirmed physical shortcut opening with search focused. Normal-build shortcut/search/close confirmed by user; multiple-display checks remain. |
| R14 | Copy-only always restores old content without Accessibility trust | C–D | PARTIAL | Hydration, private-board restore/suppression and durable recency tests pass; native Return/CmdReturn/numbered/double-click copies restored expected strings. General-board consent and final D integration remain. |
| R15 | Auto-paste closes panel, restores previous app, confirms focus, posts normal paste when trusted | D | NOT IMPLEMENTED | Paste coordinator/native validation pending. |
| R16 | Failed auto-paste leaves content copied for manual `⌘V`; no synthetic paste without trust | D | NOT IMPLEMENTED | Failure/permission regression tests pending. |
| R17 | No clipboard uploads, networking/telemetry containing data, payload logs, or real secrets in fixtures | A–F | PASS | Independent core/app review found no networking/payload logging; synthetic/private fixtures only. Restore uses currentHostOnly. Re-audit final app. |
| R18 | Exclude applications by bundle ID before capture/persistence where possible | E | NOT IMPLEMENTED | Exclusion settings and tests pending. |
| R19 | Pause/resume recording; ignore appropriate concealed/transient content | A–E | PARTIAL | Marker checks and concealed native smoke pass; pause/resume UI and multi-item handling await E. |
| R20 | Delete one item; clear unpinned/all history with confirmation | E | PARTIAL | Repository delete/clear operations exist; deletion/search-index test passes. User controls and clear confirmation await E. |
| R21 | Menu-bar Open Clipboard, Pause/Resume, Clear History, Settings, Quit | E | NOT IMPLEMENTED | Native menu-bar scene/actions pending. |
| R22 | Native ServiceManagement launch at login and useful operation without permanent Dock icon | E | NOT IMPLEMENTED | Service state and native lifecycle pending. |
| R23 | Images, copied files/folders, practical rich text and faithful multiple representations | E | NOT IMPLEMENTED | Rich payload capture/restoration pending. |
| R24 | Large payloads in Application Support, lazy row loading, deletion/retention/orphan cleanup | E | PARTIAL | Metadata-only list/search queries and explicit hydration pass tests. External blob storage and cleanup await E. |
| R25 | Source-app information presented usefully | E | PARTIAL | Name/bundle ID captured and searchable; source name shown in native rows. Final row presentation/accessibility awaits later UI gates. |
| R26 | Full keyboard operation, visible focus and VoiceOver labels | C–F | PARTIAL | Native arrow/search/preview/copy interaction, visible selection and return-to-editor checks pass. Physical shortcut/search/close confirmed by user; VoiceOver and remaining D/E actions are pending. |
| R27 | Reduce Motion, Reduce Transparency, Increase Contrast and Light/Dark support | F | NOT IMPLEMENTED | Appearance implementation and checks pending. |
| R28 | Accessibility permission requested only for needed behavior; app useful without it | D | NOT IMPLEMENTED | Permission UI and fallback pending. |
| R29 | Negligible idle work, low text-history memory, no heavy synchronous main-actor DB/image work | A–F | PARTIAL | Unchanged ticks avoid payload/hash/UI work; SQLite work stays on a repository actor and rows omit payloads. Full CPU/memory measurements and image paths remain. |
| R30 | Fast panel opening and interactive search; measure hot paths before added complexity | B–F | PARTIAL | Native interactive search passes and stale responses are rejected; panel implemented. Measured performance checks remain. |
| R31 | Multiple displays and sleep/wake reliability | E | NOT IMPLEMENTED | Layout/lifecycle implementation and available-hardware checks pending. |
| R32 | Build/run from Xcode without paid Apple Developer membership | A–F | PASS | Clean Debug build uses local ad-hoc signing without team; codesign verification and native launch passed. |
| R33 | Clean Release `.app` for trusted testers with instructions; `.dmg` optional | F | NOT IMPLEMENTED | Packaging and artifact inspection pending. |
| R34 | Neutral naming, no unapproved public release/tags/credentials | A–F | PARTIAL | Neutral internal name chosen; final artifacts/Git audit pending. |
| D01 | 760×520 compact panel slightly above center; useful 1040×640 expanded preview | C | PASS | Geometry tests and native compact/expanded preview inspection pass. Actual compact window bounds verify size and placement about 32 pt above visible center on the connected display. Multiple displays remain R31. |
| D02 | Search/filter/history/footer compact layout with readable rows, source/time/type/pin/sequence | C–F | PARTIAL | SwiftUI text rows/search/preview inspected; viewport numbering follows scrolling. Full content/accessibility review and polish remain. |
| D03 | Native glass limited to chrome/controls/footer/popovers; legible text/code/image content | F | NOT IMPLEMENTED | Final visual pass pending. |
| D04 | Continuous rounded shapes, consistent spacing, SF Symbols, system/monospaced typography, semantic colors | C–F | PARTIAL | Native text UI uses these conventions; final appearance/accessibility pass remains F. |
| D05 | Up/Down select; Return paste; `⌘Return` copy; Space/Right preview; Escape close and return focus | C–D | PARTIAL | Native selection/preview/copy actions pass; Escape/copy return the actual foreground app and editor typing. Return is explicitly copy-only until D. |
| D06 | `⌘P` pin; `⌘Delete` delete; `⌘K` clear search; `⌘1`–`⌘9` paste visible row | C–E | PARTIAL | CmdK and numbered viewport copy pass native checks. Paste bindings await D; pin/delete bindings await E. |
| D07 | Pointer interaction and explicit Copy/Pin/Delete in preview | C–E | PARTIAL | Pointer selection and double-click copy pass; preview Copy implemented. Pin/Delete controls await E. |
| D08 | Short subtle motion without continuous decoration; respects Reduce Motion | F | NOT IMPLEMENTED | Final motion pass pending. |
| D09 | General settings: shortcut, launch at login, menu-bar visibility, retention | E | NOT IMPLEMENTED | Settings pending. |
| D10 | Privacy settings: pause, exclusions, transient handling, clear; Permissions: AX status/explanation | D–E | NOT IMPLEMENTED | Settings and native checks pending. |
| G01 | Every gate independently reviewed, built/tested, accepted, committed and pushed | A–F | PARTIAL | A–C passed independent review, tests, clean signed builds and scoped native checks; publication receipts are Git history. D–F remain. |
| G02 | Final independent architecture/privacy/Swift/performance/UI/test/packaging review, findings fixed | F | NOT IMPLEMENTED | Requires full V1 implementation. |

Native checks that require unavailable hardware, permissions, or interaction must be recorded honestly
as unverified with the specific reason. They cannot be replaced by unrelated passing unit tests.
