# macOS Clipboard Manager — AGENT.md

Read this file first, then:

1. `REQUIREMENT.md`
2. `DESIGN.md`
3. only the source/tests relevant to the current task

Keep the implementation simple.

---

## 1. Stack Rule

This is a **native macOS application**.

Use only the native Swift/macOS stack unless the requirements explicitly change:

- Swift 6,
- SwiftUI,
- AppKit where required,
- ApplicationServices/CoreGraphics where required,
- `NSPasteboard`,
- SQLite,
- SF Symbols,
- native macOS APIs.

Do **not** introduce or mix in:

- React,
- React Native,
- Expo,
- Electron,
- Tauri,
- JavaScript/TypeScript UI,
- Node.js,
- Bun,
- webviews as the primary UI,
- Firebase,
- a backend service.

Do not solve a native macOS problem by adding another application stack.

---

## 2. Skills Rule

Before implementing a task, discover the available coding skills/instructions relevant to the work.

Use only skills directly related to this project's native stack, for example:

- Swift,
- SwiftUI,
- AppKit,
- macOS,
- Xcode,
- Apple platform development,
- SQLite when relevant to persistence.

If multiple skills exist, choose the smallest relevant set.

Do **not** load or apply unrelated skills for:

- React,
- Expo,
- React Native,
- Node/Bun,
- Electron,
- Tauri,
- frontend web frameworks,
- backend frameworks.

If no Swift/macOS-specific skill is available, continue with the repository requirements and native Apple APIs. Do not substitute another stack.

Repository requirements always take precedence over generic skill suggestions.

---

## 3. Main Principles

Prefer:

- native behavior,
- small focused types,
- clear code,
- few dependencies,
- testable boundaries,
- local-first privacy,
- correctness over cleverness.

Avoid:

- premature abstractions,
- unnecessary protocols,
- giant architecture layers,
- duplicate helper types,
- speculative features,
- dependency-heavy solutions.

Do not create a complicated architecture just because the project may grow later.

---

## 4. Native UI

Use SwiftUI for normal UI.

Use AppKit only when SwiftUI does not provide reliable access to required macOS behavior, such as:

- floating panel/window behavior,
- application activation,
- focus restoration,
- first-responder behavior,
- pasteboard integration,
- system-level window handling.

Do not rebuild the entire UI in AppKit.

---

## 5. Liquid Glass

Follow `DESIGN.md`.

Use native macOS 26 visual APIs.

Rules:

- use glass for shell/chrome/controls,
- keep clipboard content readable,
- prefer system materials and semantic colors,
- support Light/Dark Mode,
- respect Reduce Transparency and Increase Contrast,
- avoid fake neon/glow glass,
- avoid excessive nested glass surfaces.

Do not spend time polishing visual effects before the clipboard workflow works correctly.

---

## 6. Clipboard Code

Clipboard monitoring must be lightweight.

- Use `NSPasteboard.changeCount`.
- Do not busy-loop.
- Do expensive work only when content changes.
- Handle unsupported types safely.
- Prevent internal write-back from creating duplicate entries.
- Never log full clipboard content.
- Apply exclusion/privacy rules before persistence when possible.

Clipboard-reading logic must not live directly inside SwiftUI views.

---

## 7. Persistence

Use SQLite for persistent history.

Keep database access outside views.

Requirements:

- migrations for schema changes,
- transactions where consistency matters,
- FTS/search index kept consistent,
- avoid loading large blobs for normal history rows,
- clean unused blob files,
- never expire pinned items through normal retention.

Do not add a remote database.

---

## 8. Auto-Paste

Keep auto-paste/focus logic centralized.

Expected flow:

```text
remember previous app
→ user chooses item
→ write item to pasteboard
→ close panel
→ reactivate previous app
→ confirm/wait for focus
→ send paste
```

Rules:

- no synthetic paste without Accessibility permission,
- copy-only must always work,
- avoid arbitrary long sleeps,
- prevent internal pasteboard writes from entering history,
- test focus restoration after changing window behavior.

---

## 9. Privacy

Clipboard data is sensitive.

Never:

- upload clipboard content,
- log clipboard payloads,
- add analytics containing content,
- put real secrets in tests,
- intentionally capture excluded apps.

If a proposed feature requires networking, new permissions, or remote storage, stop and treat it as a requirement change.

---

## 10. Dependencies

Prefer Apple frameworks and standard libraries.

Add a third-party package only when it clearly reduces risk or complexity.

Before adding one, check:

- why it is needed,
- whether native APIs are enough,
- maintenance status,
- license,
- whether the dependency is larger than the problem.

Do not add multiple libraries for the same concern.

---

## 11. Source Layout

Keep the repository small and feature-oriented.

A reasonable starting layout is:

```text
App/
Clipboard/
Persistence/
System/
Features/
DesignSystem/
Tests/
```

Create deeper folders only when real code requires them.

Do not create empty architecture folders in advance.

---

## 12. Swift Rules

- Use modern Swift 6.
- Respect concurrency checks.
- Avoid force unwraps and `try!` in production code.
- Prefer value types for simple immutable models.
- Prefer `final` classes when subclassing is unnecessary.
- Keep UI state on the main actor where required.
- Keep side effects outside SwiftUI rendering.
- Do not silence concurrency warnings without a documented reason.

Keep code readable for a developer who is still learning Swift.

Prefer straightforward Swift over clever or highly abstract Swift.

---

## 13. Testing

Add tests for logic that can be tested reliably.

Priority tests:

- hashing/deduplication,
- self-write suppression,
- retention,
- app exclusions,
- classification,
- search/filtering,
- SQLite migrations/repository behavior.

Manually verify native system behavior such as:

- global shortcut,
- floating panel,
- focus restoration,
- auto-paste,
- Accessibility permission,
- multi-monitor behavior,
- menu bar,
- Liquid Glass appearance.

---

## 14. Build Check

Before finishing a task:

1. Build the macOS target.
2. Run relevant tests.
3. Fix warnings introduced by the change.
4. Manually test affected native behavior when necessary.
5. Check the diff for unrelated edits.
6. Confirm no real clipboard content was logged or committed.

Do not leave the repository knowingly broken.

---

## 15. Implementation Order

Unless a task says otherwise:

1. Project skeleton.
2. Clipboard monitor.
3. In-memory history.
4. SQLite persistence.
5. Search.
6. Floating `⌘⇧V` panel.
7. Keyboard workflow.
8. Copy and auto-paste.
9. Menu bar/settings/launch at login.
10. Images/files/rich text.
11. Privacy/exclusions.
12. Multi-monitor and reliability pass.
13. Liquid Glass polish.
14. Build/package for trusted testers.

Do not jump ahead to optional features while earlier core behavior is incomplete.

---

## 16. Scope

Implement only what is required for the current task.

If you notice an unrelated improvement, leave a short note rather than expanding scope.

The goal is a small, reliable native macOS clipboard manager—not a framework or cross-platform product.
