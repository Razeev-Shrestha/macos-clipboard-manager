# Gate F performance measurements

> **Before running the runner or direct probe, quit any Debug app using the Gate F fixture.** The reset removes and recreates SQLite files, so an app with `build/GateFPerformance/history.sqlite` open can hold stale handles. The runner and probe refuse to proceed when either fixture database is open; they never kill a process.

`Scripts/measure-performance.sh` builds a standalone, optimized Swift probe from the current `ClipboardCore` sources and runs it against isolated fixtures. The probe uses `swiftc -swift-version 6 -O -whole-module-optimization -warnings-as-errors`; it does not add a production target or dependency.

Run it from the repository root:

```sh
./Scripts/measure-performance.sh
```

The probe accepts only the `--reset-dataset` flag. It derives the fixture root from the compiled source location, so callers cannot supply an arbitrary storage directory, database path, or pasteboard name. The runner and probe reject symlinked fixture components, symlinked database/output paths, unexpected directories at database filenames, and non-regular database sidecars before writing or removing anything. The runner creates only its own `build/GateFPerformance` files. With `--reset-dataset` it removes the exact probe database paths (`history.sqlite`, their SQLite `-wal`/`-shm` sidecars) before reseeding; it does not recursively delete the directory or unrelated files. Before the normal run, the script creates sacrificial sentinel, symlink, directory, and open-file fixtures inside the owned Gate F directory and verifies that arbitrary path, General-pasteboard, unknown-option, malformed-option, unsafe-component, unexpected-directory, and open-database attempts are rejected. The resulting fixtures remain available after the command completes:

- `build/GateFPerformance/history.sqlite` contains 1,000 deterministic synthetic text rows.
- `build/GateFPerformance/large/large-history.sqlite` contains the large-payload fixture and its isolated `blobs` directory.
- The named pasteboard is `com.example.ClipboardManager.gate-f-performance` and contains one synthetic marker item. The General pasteboard is never read or written.

The main app can open the text fixture in a Debug run with these exact arguments:

```text
--test-pasteboard com.example.ClipboardManager.gate-f-performance
--test-storage-directory /Users/rajeevshrestha/Projects/macos-clipboard-manager/build/GateFPerformance
```

The probe prints only operation metadata, counts, timings, and hardware/build context. It never prints captured text, representation bytes, hashes, or database payloads.

## Method

The unchanged-poll measurement drives `NSPasteboardMonitor` with an isolated in-memory `ClipboardPasteboard`. It warms the monitor baseline, then performs 10,000 unchanged polls and records whether any payload read occurred. This timing measures the monitor state machine and deliberately excludes native pasteboard IPC; the named AppKit pasteboard is seeded separately for the native app fixture.

The history benchmark opens a fresh SQLite database, inserts 1,000 deterministic text items, warms one metadata query, one FTS search, and one selected-item hydration, then samples the warm operations. Query results are metadata-only; selected hydration is the explicit `item(id:)` payload load. The large-payload benchmark uses a separate database and measures SHA-256 identity, blob-backed record, and blob hydration for 1 MiB synthetic data. Repository open, directory creation, fixture construction, and warmup calls are setup and excluded from the reported warm samples. Per-item insertion timings and total seed time are both reported.

The command was last run on 2026-09-12 using macOS 26.6.2 (arm64, 10 logical CPUs, 16 GiB physical memory) with the optimized Swift build described above. The observed output was:

| Operation | Samples | p50 | p95 | Result metadata |
| --- | ---: | ---: | ---: | --- |
| Unchanged poll | 10,000 | 0.000041 ms | 0.000042 ms | 10,000 unchanged; 0 payload reads |
| Text history insert | 1,000 | 0.467541 ms | 0.625583 ms | 489.641208 ms total; 1,000 rows |
| Metadata query | 30 | 2.285083 ms | 2.392708 ms | 1,000 rows |
| FTS search | 30 | 0.030583 ms | 0.037792 ms | 1 result |
| Selected text hydration | 30 | 0.030958 ms | 0.037417 ms | 1 result; 34 bytes |
| 1 MiB payload hash | 12 | 0.361000 ms | 0.408166 ms | 12 identities |
| 1 MiB payload store | 12 | 2.119042 ms | 2.608250 ms | 12 blob-backed rows |
| 1 MiB payload hydration | 12 | 1.273458 ms | 1.321000 ms | 1 result; 1,048,576 bytes |

The values are a reproducible baseline for this machine and build. They are measurements, not acceptance thresholds or optimization claims. Repeat the probe after source or toolchain changes when comparing results.

## Native app measurements

Native measurements used the reviewed Debug app on the same machine, a SQLite backup containing
1,000 synthetic text rows, and a separate private named pasteboard. Keeping the GUI fixture separate
prevents another benchmark reset from invalidating the app's open database. No General pasteboard
content was used. The app reopened successfully after both idle measurements and the database
retained 1,000 rows with integrity `ok`.

| Native behavior | Measurement | Method / build |
| --- | --- | --- |
| Panel idle CPU | Open 0.083%; closed 0.050% of one core | Separate 60-second intervals; process CPU-time delta / elapsed time |
| Panel idle RSS | Open 112.02–115.22 MiB; closed 113.06–113.08 MiB | `ps` RSS sampled every five seconds; includes resident framework pages |
| First observed panel open | 534 ms | One native reopen plus automation and accessibility observation, after process startup |
| Search response | 465 ms | One typed query over 1,000 rows to an observed single result; includes input/observation overhead |
| Selected preview open | 494 ms | Right Arrow to observed matching text preview; includes automation overhead |
| Copy and paste flow | Exact native image and text restoration; copy-only left editor unchanged | Gate F AX Copy/CmdReturn; native trusted insertion was established in Gate D |

The GUI timings are end-to-end automation observations, not app-only latency or physical global-key
dispatch measurements. The optimized CLI timings above separately measure SQLite and payload paths.
The physical global shortcut was confirmed by the user in Gate C. A Gate F automatic-paste retry
captured a destination outside the synthetic allowlist because automation focus differed from the
desktop foreground process; it correctly copied without posting. That retry is not claimed as a new
successful insertion or a paste-latency measurement.

The first open-panel idle sample consumed 14.8% of one core. A five-second native stack sample showed
SwiftUI `TimeDataSource.DateBox`, `SystemFormatStyle.DateOffset`, and dynamic text/layout work. Replacing
each row's live relative-time label with a localized static copied timestamp reduced the final open-panel
sample to 0.083%. This preserves the required timestamp without continuous row updates. An earlier
closed-panel sample was discarded because a concurrent fixture reset had invalidated that app's database;
the final measurements above use the separate healthy backup and the runner now rejects open databases.
