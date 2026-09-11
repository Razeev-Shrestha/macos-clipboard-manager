# Goal

Build the macOS clipboard manager defined by:

1. `AGENT.md`
2. `REQUIREMENT.md`
3. `DESIGN.md`

These files are the source of truth.

Your role is **lead/orchestrator**, not primary implementer.

Your responsibility is to take the repository from its current state to a reliable, tested, native macOS application while delegating the actual implementation, review, testing, debugging, and focused research to cheaper capable agents wherever possible.

Do not try to implement the whole application yourself.

---

# 1. Start by Understanding the Repository

Before changing code:

1. Read `AGENT.md` completely.
2. Read `REQUIREMENT.md` completely.
3. Read `DESIGN.md` completely.
4. Inspect the entire current repository.
5. Inspect the Git status, current branch, and configured remote.
6. Determine what already exists and what is still missing.
7. Build a concise implementation plan based on the delivery order in `REQUIREMENT.md`.
8. Track completed and remaining work internally throughout the run.

Do not invent a different architecture or product direction when the repository documents already answer the question.

If documentation conflicts:

```text
AGENT.md
    ↓
REQUIREMENT.md
    ↓
DESIGN.md
    ↓
existing implementation
```

Use this precedence unless a requirement clearly indicates otherwise.

---

# 2. Your Role

You are the **main supervising agent**.

You should primarily:

* inspect,
* plan,
* delegate,
* review,
* coordinate,
* verify,
* integrate,
* run final checks,
* manage milestone completion,
* manage milestone Git commits,
* resolve disagreements between agents.

You should **not** be the primary feature developer.

Delegate implementation work whenever a suitable subagent/model is available.

Only implement code yourself when:

* delegation is unavailable,
* a very small integration fix is required,
* an agent repeatedly fails on the same narrowly scoped issue,
* or direct intervention is clearly cheaper and safer than another delegation cycle.

Even then, keep direct changes small.

---

# 3. Model Usage

Use inexpensive capable models for almost all delegated work.

Prefer models such as:

```text
Terra
Luna Max
```

or the closest available low-cost capable models.

Use them for:

* repository exploration,
* Swift implementation,
* SwiftUI work,
* AppKit integration,
* tests,
* bug fixing,
* code review,
* documentation lookup,
* build-error investigation,
* regression checks.

Prefer the **cheapest model capable of completing the task correctly**.

A reasonable default is:

```text
straightforward implementation
    → Terra

tests / repository inspection
    → Terra

focused bug fixes
    → Terra

complex Swift/AppKit interaction
    → Luna Max

architecture-sensitive changes
    → Luna Max

independent review
    → Luna Max or another fresh capable agent
```

Do not use an expensive main-agent context to perform work that a cheaper subagent can perform.

The main agent should preserve its context for:

* coordination,
* architecture,
* reviewing results,
* resolving conflicts,
* milestone acceptance,
* and final validation.

---

# 4. Skills Are Mandatory

Before delegating implementation, discover the available skills relevant to the task.

Only use skills related to this application's native stack, including when available:

* Swift,
* Swift 6,
* SwiftUI,
* AppKit,
* macOS development,
* Xcode,
* Apple platform development,
* NSPasteboard,
* Accessibility APIs,
* CoreGraphics/ApplicationServices,
* ServiceManagement,
* SQLite,
* XCTest / Swift Testing,
* native Apple UI and Liquid Glass.

Give the relevant skill to the delegated agent or explicitly instruct the agent to load/use it.

Use the **smallest relevant skill set**.

Do not load unrelated skills.

Never introduce:

* React,
* React Native,
* Expo,
* Electron,
* Tauri,
* JavaScript UI,
* TypeScript UI,
* Node.js,
* Bun,
* Firebase,
* web frameworks,
* webviews as the primary UI,
* backend frameworks,
* unnecessary server infrastructure.

This is a native macOS project.

If no appropriate Swift/macOS skill exists, use native Apple documentation/APIs and the repository requirements.

Do not substitute another technology stack.

---

# 5. Delegation Strategy

Break work into **small, bounded tasks**.

Bad delegation:

> Build the entire clipboard manager.

Good delegation:

> Implement the clipboard monitor using NSPasteboard.changeCount according to REQUIREMENT.md and AGENT.md. Add focused unit tests. Do not modify unrelated UI.

Another good delegation:

> Implement the SQLite history repository and migrations only. Preserve the existing ClipboardItem model. Add tests for insert, deduplication, retention, pin preservation, and migration behavior.

Each implementation task should specify:

```text
Goal
Relevant files
Relevant requirements
Relevant skill(s)
What may be changed
What must not be changed
Required tests
Definition of done
```

Avoid giving multiple agents overlapping ownership of the same files at the same time.

Parallelize only work that is genuinely independent.

---

# 6. Preferred Work Cycle

Use this cycle for each meaningful feature:

```text
MAIN AGENT
    ↓
define bounded task
    ↓
IMPLEMENTATION AGENT
Terra / Luna Max
    ↓
implementation + tests
    ↓
MAIN AGENT
inspect diff
    ↓
INDEPENDENT REVIEW AGENT
fresh context
    ↓
correctness / Swift / privacy /
requirements / regression review
    ↓
FIX AGENT
if required
    ↓
TEST / VALIDATION AGENT
    ↓
build + tests + native checks
    ↓
MAIN AGENT
accept or reject
```

The agent that implements a significant feature should generally **not be the only agent reviewing it**.

Use fresh-context review whenever practical.

Do not create a Git milestone commit for every small delegated task.

Individual feature work should accumulate toward a coherent milestone.

---

# 7. Review Requirements

Every significant implementation must be reviewed for:

## Correctness

Does it satisfy the relevant requirements?

## Native macOS behavior

Does it behave like a native macOS application rather than recreating web patterns?

## Swift quality

Check for:

* unsafe force unwraps,
* unnecessary abstractions,
* concurrency problems,
* incorrect actor usage,
* retain cycles,
* blocking main-thread work,
* duplicated types,
* overengineering,
* misuse of SwiftUI state,
* unnecessary AppKit,
* unnecessary dependencies.

## Privacy

Confirm:

* clipboard contents are never uploaded,
* clipboard payloads are not logged,
* excluded applications are respected,
* test fixtures contain no real secrets,
* internal clipboard writes do not create unwanted history,
* networking has not been introduced.

## Scope

Reject unrelated refactoring unless necessary for the current feature.

## Simplicity

If two implementations work equally well, choose the simpler one.

This project should remain easy for a developer learning Swift to understand.

---

# 8. Testing Standard

Do not treat compilation as sufficient testing.

For every feature, determine the appropriate combination of:

```text
unit tests
integration tests
build verification
manual native-macOS verification
regression testing
```

Automated tests should cover logic wherever practical, especially:

* clipboard hashing,
* deduplication,
* self-write suppression,
* retention,
* pin preservation,
* filtering,
* search,
* app exclusions,
* classification,
* SQLite repository behavior,
* SQLite migrations,
* state transitions.

System behavior must additionally be manually validated when practical:

* global `⌘⇧V`,
* floating panel behavior,
* keyboard navigation,
* focus handling,
* previous-app restoration,
* copy-only behavior,
* automatic paste,
* Accessibility permission handling,
* menu-bar behavior,
* launch at login,
* multiple displays,
* Light Mode,
* Dark Mode,
* Reduce Transparency,
* Increase Contrast,
* Reduce Motion,
* sleep/wake behavior.

If the environment prevents a manual macOS interaction test, explicitly identify what remains unverified instead of pretending it passed.

---

# 9. Build Discipline

After every coherent feature:

1. Build the macOS target.
2. Run relevant tests.
3. Fix compiler warnings introduced by the change.
4. Inspect the diff.
5. Check for unrelated modifications.
6. Check that no sensitive clipboard data was introduced.
7. Confirm the repository remains buildable.

Before completing a milestone:

1. Build the entire macOS target cleanly.
2. Run the complete relevant automated test suite.
3. Run milestone-specific native behavior checks.
4. Perform an independent code review.
5. Fix accepted review findings.
6. Re-run tests after fixes.
7. Inspect final Git diff.
8. Confirm no secrets or user clipboard data are present.
9. Confirm the milestone requirements are genuinely complete.

Never knowingly continue building on top of a broken milestone.

---

# 10. Do Not Overengineer

Keep the repository small.

Prefer:

* simple Swift,
* simple SwiftUI,
* small focused types,
* native Apple frameworks,
* explicit behavior,
* focused tests.

Avoid:

* architecture for hypothetical future requirements,
* excessive protocols,
* unnecessary dependency injection frameworks,
* generic abstraction layers,
* giant coordinators,
* giant view models,
* unnecessary packages,
* premature optimization,
* custom design systems where native macOS APIs already solve the problem.

Create abstractions only after a real duplication or testing need exists.

---

# 11. Dependencies

Apple frameworks and the Swift standard library are preferred.

Before allowing a third-party dependency, delegate a quick evaluation covering:

```text
Why is it required?
Can native APIs solve the same problem?
How maintained is it?
What is its license?
What does it add to the binary/project?
Is it larger or more complex than implementing the requirement natively?
```

Do not add a dependency merely because an agent is familiar with it.

Do not add multiple packages solving the same problem.

---

# 12. UI Development

Do not start by polishing Liquid Glass.

Follow the product priority:

```text
correct clipboard behavior
        ↓
correct persistence
        ↓
correct search
        ↓
correct keyboard workflow
        ↓
correct paste/focus behavior
        ↓
privacy/reliability
        ↓
Liquid Glass polish
```

When UI work begins:

* use SwiftUI first,
* use native macOS 26 components,
* use Liquid Glass only where `DESIGN.md` calls for it,
* use SF Symbols,
* use semantic system colors,
* support Light and Dark Mode,
* respect macOS accessibility settings,
* keep clipboard content highly readable.

Do not create fake Liquid Glass with excessive blur, glow, or custom gradients.

---

# 13. AppKit Boundary

SwiftUI remains the primary UI technology.

Use AppKit only where it provides necessary macOS behavior, such as:

* floating utility panel behavior,
* NSWindow/NSPanel control,
* NSPasteboard integration,
* focus management,
* application activation,
* responder chain behavior,
* system-level window behavior.

Do not allow an implementation agent to migrate the entire UI to AppKit simply because one feature requires AppKit.

---

# 14. Research

When an agent is uncertain about a macOS API or modern Swift behavior:

1. use an appropriate Swift/macOS skill,
2. consult current Apple documentation where possible,
3. verify that the API applies to macOS 26+,
4. return a concise recommendation,
5. implement only after resolving the uncertainty.

Do not guess Apple API behavior when it can reasonably be verified.

Avoid broad research when the answer already exists in the repository documents.

---

# 15. Implementation Order

Follow `REQUIREMENT.md`.

At a high level:

```text
1. Xcode / Swift project skeleton
2. clipboard monitoring
3. in-memory text history
4. SQLite persistence
5. search
6. floating panel + ⌘⇧V
7. keyboard navigation
8. copy selected item
9. auto-paste + focus restoration
10. menu bar + launch at login
11. pin/delete/clear/pause
12. images/files/rich text
13. app exclusions + privacy hardening
14. multi-monitor + sleep/wake reliability
15. Liquid Glass polish
16. packaging for trusted testers
```

Do not skip ahead because a later feature is more interesting.

A later phase may begin early only when it is an independent prerequisite or a tiny foundation required by an earlier task.

---

# 16. Milestone Gates

Do not move past a gate until it is implemented, reviewed, and tested.

## Gate A — Clipboard Core

Must have:

* project builds,
* NSPasteboard monitoring,
* in-memory history,
* self-write suppression,
* deduplication,
* tests.

When Gate A passes:

```text
review
→ build
→ test
→ commit
→ push to GitHub
```

Suggested commit:

```text
feat: complete clipboard core
```

---

## Gate B — Persistent History

Must have:

* SQLite persistence,
* migrations,
* retention behavior,
* search,
* restart persistence,
* tests.

When Gate B passes:

```text
review
→ build
→ test
→ commit
→ push to GitHub
```

Suggested commit:

```text
feat: add persistent clipboard history and search
```

---

## Gate C — Daily Workflow

Must have:

* global shortcut,
* floating panel,
* keyboard navigation,
* copy selected item,
* reliable close/focus behavior.

When Gate C passes:

```text
review
→ build
→ test
→ commit
→ push to GitHub
```

Suggested commit:

```text
feat: complete keyboard clipboard workflow
```

---

## Gate D — Auto Paste

Must have:

* Accessibility detection,
* previous-app tracking,
* safe focus restoration,
* automatic paste,
* graceful copy-only fallback,
* regression testing.

When Gate D passes:

```text
review
→ build
→ test
→ commit
→ push to GitHub
```

Suggested commit:

```text
feat: add automatic paste and focus restoration
```

---

## Gate E — Full V1

Must have:

* menu bar,
* launch at login,
* pins,
* deletion/clearing,
* pause,
* source-app information,
* images/files,
* exclusions,
* privacy protections,
* multi-display reliability.

When Gate E passes:

```text
review
→ build
→ full tests
→ commit
→ push to GitHub
```

Suggested commit:

```text
feat: complete v1 clipboard functionality
```

---

## Gate F — Polish & Distribution

Must have:

* Liquid Glass implementation,
* accessibility appearance checks,
* performance check,
* clean Release build,
* `.app`,
* optional `.dmg`,
* tester instructions.

When Gate F passes:

```text
final independent review
→ clean Release build
→ full test suite
→ packaging verification
→ commit
→ push to GitHub
```

Suggested commit:

```text
release: prepare macos clipboard manager v1
```

---

# 17. GitHub Milestone Workflow

After **every completed milestone**, commit the accepted work and push it to the configured GitHub repository.

Do this only after the milestone has passed its quality gate.

The required sequence is:

```text
implementation complete
        ↓
independent review
        ↓
fix findings
        ↓
build succeeds
        ↓
tests succeed
        ↓
manual checks where applicable
        ↓
inspect git diff
        ↓
stage milestone files
        ↓
commit
        ↓
push to GitHub
```

Before committing:

```bash
git status
git diff
git diff --staged
```

Inspect what will be committed.

Never blindly run:

```bash
git add .
```

without first understanding the working tree.

Stage only files belonging to the accepted milestone.

Use clear commit messages.

Prefer:

```text
feat: complete clipboard core
feat: add sqlite clipboard persistence
feat: add clipboard search
feat: add global clipboard panel
feat: add automatic paste support
feat: add clipboard privacy controls
fix: restore previous app focus reliably
test: add clipboard repository coverage
refactor: simplify clipboard monitor
docs: update tester instructions
release: prepare v1
```

Avoid meaningless messages such as:

```text
update
changes
fix stuff
work
wip
```

Do not commit a milestone if:

* the build is broken,
* required tests fail,
* a high-severity review issue remains,
* unrelated changes are mixed into the diff,
* secrets are present,
* user clipboard contents are present,
* generated/build files are accidentally staged.

After committing:

```bash
git status
```

Confirm the working tree is in the expected state.

Then push the current branch to its configured GitHub remote.

For example:

```bash
git push
```

or, if upstream is not configured:

```bash
git push -u origin <current-branch>
```

Do not:

* force push,
* rewrite published history,
* delete remote branches,
* modify GitHub credentials,
* change repository visibility,
* create releases automatically,
* create tags automatically,

unless explicitly required later.

If authentication or remote configuration prevents pushing:

1. keep the valid local commit,
2. report the exact push problem,
3. continue only if doing so will not risk losing work.

A GitHub push failure does not justify rewriting or deleting a valid milestone commit.

---

# 18. Quality Gate for V1

Do not declare V1 complete until all required functionality in `REQUIREMENT.md` is accounted for.

Produce a requirement checklist with each V1 requirement marked:

```text
PASS
PARTIAL
NOT IMPLEMENTED
BLOCKED
```

Anything marked:

```text
PARTIAL
NOT IMPLEMENTED
BLOCKED
```

must include a short explanation.

Then perform one final independent review covering:

* architecture,
* requirements,
* privacy,
* Swift correctness,
* performance,
* UI consistency,
* tests,
* packaging.

Fix high- and medium-severity issues before declaring completion.

Run the full validation suite again after those fixes.

The final V1 state should then receive its final milestone commit and GitHub push.

---

# 19. Git Safety

Work only inside this repository.

Do not:

* rewrite unrelated history,
* delete user work,
* force push,
* commit secrets,
* commit certificates/private keys,
* commit provisioning credentials,
* commit build artifacts that should be ignored,
* modify repository credentials,
* push broken milestones.

Use Git frequently to inspect the current state.

Keep milestone commits coherent.

Small intermediate local commits are allowed if useful for safety, but milestone completion should produce a clean, understandable Git history.

Do not squash or rewrite already-pushed milestone commits unless explicitly instructed.

---

# 20. Handling Agent Failure

If a delegated agent fails:

1. inspect why,
2. narrow the task,
3. provide relevant error/output,
4. retry with a capable cheap model,
5. use Luna Max for harder debugging when Terra is insufficient.

Do not repeatedly send the identical vague task.

If two agents independently fail, reassess the architecture/API assumption before attempting a third implementation.

---

# 21. Communication

Do not flood the user with every subagent action.

Report meaningful milestones such as:

```text
Clipboard core complete and pushed
Persistence/search complete and pushed
Global panel workflow complete and pushed
Auto-paste complete and pushed
V1 functionality complete and pushed
Final review complete
```

For a completed milestone, provide a concise summary containing:

```text
Milestone
What was implemented
Tests/build status
Review status
Commit hash
Branch
Push status
Anything still unverified
```

Surface important issues immediately if they affect:

* architecture,
* privacy,
* required permissions,
* feasibility,
* data loss,
* distribution,
* Git history,
* major requirement changes.

Otherwise continue executing the documented goal autonomously.

---

# 22. Definition of Success

Success is not:

> lots of generated Swift files.

Success is:

> a small, understandable, native Swift/macOS clipboard manager that fulfills REQUIREMENT.md, follows DESIGN.md, obeys AGENT.md, builds cleanly, is properly tested, behaves reliably during daily use, protects clipboard privacy, and can eventually be packaged for trusted Mac testers.

And the repository should tell a clean story through Git:

```text
Milestone A
    ↓
reviewed + tested
    ↓
commit + push

Milestone B
    ↓
reviewed + tested
    ↓
commit + push

Milestone C
    ↓
reviewed + tested
    ↓
commit + push

...

V1
    ↓
final review
    ↓
release-ready commit
    ↓
GitHub
```

Favor correctness and reliability over amount of code.

Favor native macOS behavior over custom behavior.

Favor delegation over doing implementation work in the main-agent context.

Favor cheap capable subagents over expensive models for routine work.

Favor simple Swift over clever Swift.

**Never commit merely because code was written. Commit because a milestone has been reviewed, tested, and accepted.**

Continue until the current milestone is genuinely complete, reviewed, tested, committed, and pushed.
