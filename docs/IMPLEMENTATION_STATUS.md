# Implementation status

Status for Microgravity 0.1.0, checked 2026-11-06 on macOS 27.2 (arm64), Xcode
27.2 (27B52), Node.js 26.13.0. Results are for the working tree on top of commit
`2cd7618`. Re-run the gates before tagging.

Intended behavior is in [UI acceptance](UI_ACCEPTANCE.md). Collector, history,
and process-action regressions are in [core failure cases](FAILURE_CASES_CORE.md).
The release procedure and the 0.1.0 UI gate are in [RELEASING.md](RELEASING.md).

## Verification

| Gate | Command | Result |
| --- | --- | --- |
| Workspace validation | `npm run validate` | pass |
| Project and version sync | `npm run project:sync -- --check`, `npm run sync-version -- --check` | pass |
| Node tests | `npm run test:node` | 32 passed, 0 failed |
| Core XCTest | Core command in [RELEASING.md](RELEASING.md) | 199 executed, 0 failures |
| Debug build | `npm run build:debug` | pass (unsigned development app) |
| Release smoke | `npm run build:release-smoke` | pass (unsigned universal Release compile) |
| Bundle icon check | `validateWorkspace({ bundle })` against the Debug app | pass |
| Strict concurrency diagnostics | build with `SWIFT_STRICT_CONCURRENCY=complete`, warnings not errors | build succeeds; 0 errors, 29 warnings (see below) |
| Signed UI XCTest | signed command in [RELEASING.md](RELEASING.md) | not run in this pass; not passing on any host for 0.1.0 |
| Manual UI checklist | [RELEASING.md](RELEASING.md) | not done |
| Hosted CI | `.github/workflows/ci.yml` | not run from this tree |

The UI XCTest suite (`Tests/UITests`, 13 tests) has not passed for 0.1.0. The
last signed runs recorded in the removed `TEST_RESULTS.md` (2026-11-05, earlier
code) failed on synthesized clicks and keystrokes, which did not reach the app
in the test VM. The cause has not been isolated. The file remains in git
history.

Automation Mode was not enabled for this pass. Enabling it requires an
administrator, and this pass did not run the signed UI suite.

## Implemented

Core:

- Every reading is available, partial, warming up, unavailable, or not
  supported. Unavailable values are never shown as zero.
- Per-process CPU converts `proc_taskinfo` Mach ticks to nanoseconds with
  `mach_timebase_info`. Process CPU is normalized across logical cores.
- Network totals exclude loopback, virtual, and tunnel interfaces. The
  per-interface list keeps every interface and marks which ones are included in
  totals.
- Memory pressure starts from `kern.memorystatus_vm_pressure_level` and is then
  refined by the dispatch source.
- Process identity is PID plus start time. Names and paths are cached per
  identity. The 16,384-PID enumeration cap and identity omissions are reported
  with a named detail.
- Sampling uses a deadline grid on `ContinuousClock`, so collection time does
  not stretch the interval. Snapshots are published before the SQLite history
  write. Retention deletes run once per UTC day.
- History is SQLite in WAL mode, 30 days, sliced by UTC day. A failed write marks
  the next record as a gap.
- Local Quit and Force Quit revalidate the selected identity before signalling.
  The privileged helper follows the policy in
  [UI acceptance](UI_ACCEPTANCE.md#process-action-policy-privileged-helper).

Integration:

- The privileged helper checks the client code signature, accepts fixed
  commands only, bounds its output, and uses single-use authorization.
- The three XPC single-reply wrappers share `XPCSingleReply`.
- Advanced metrics run through the helper (see [ADVANCED_METRICS.md](ADVANCED_METRICS.md)).
- Sparkle automatic checks stay off unless a public key is configured.

UI (AppKit):

- Window opens at 1280 × 820, minimum 960 × 600, and autosaves its frame.
- Unified toolbar with page-specific items, source-list sidebar (Monitor and
  Inventory groups, status footer), View, Window, Help, Process menus, and
  Settings and Check for Updates items.
- Processes is an outline view with app icons, heat-mapped cells, partial and
  unavailable badges with tooltips, a selection bar, a context menu, and sheets.
- Performance has a metric rail with sparklines, a detail graph with grid, axis
  labels, gap markers, a time-window picker, per-core activity, a swap capacity
  bar, and a memory pressure timeline.
- App History is one application-to-day outline.
- Startup and Services are read-only, with status, kind labels, a coverage
  banner, Reveal in Finder, and Open Login Items Settings.
- Users and Details are refreshed to match the new layout.
- Settings is a form for appearance, interval, pause, history reset, helper,
  login item, and updates.
- Force Quit and Reset History confirmations are window sheets.
- App icon: `Info.plist` declares `CFBundleIconName` as `microgravity`, and the
  app target sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `microgravity`. The
  built Debug app contains the icon in `Assets.car` and a `microgravity.icns`
  fallback. `scripts/validate.mjs` checks both. The icon has not been viewed in
  the Dock, About panel, or Force Quit dialog.

## Known gaps

1. **UI XCTest.** Not passing and not run in this pass. The 0.1.0 UI verification
   is the Core XCTest suite plus the manual checklist in
   [RELEASING.md](RELEASING.md).
2. **Script versus documented UI gate.** `npm run test:all` runs the whole `Test`
   scheme, including the UI target, and `release:prepare` calls `test:all`. A
   failing UI suite therefore blocks release preparation. This conflicts with the
   0.1.0 decision and is not resolved in the docs. Details are in
   [RELEASING.md](RELEASING.md#ui-tests-and-the-release-gate).
3. **Manual visual pass.** Light, dark, and System appearance at 1280 × 820 and
   960 × 600, and screenshots, are pending. No screenshots are committed.
4. **Strict concurrency.** `SWIFT_STRICT_CONCURRENCY = complete` is not set in
   the project. A diagnostic build with it set succeeds with 0 errors and 29
   warnings. Warnings are in `SamplingRunner.swift` (12), `AppComposition.swift`
   (6), `TerminationService.swift` (4), `SettingsViewController.swift` (2),
   `MetricGraphView.swift` (2), `SQLiteMonitoringHistoryStore.swift` (1),
   `SystemMonitorCollector.swift` (1, the `events` send inside the
   memory-pressure event handler's `Task`), and one Objective-C warning from the
   vendored Sparkle sources. Most of the warnings say they become errors in the
   Swift 6 language mode. The count is from this one build; re-run before
   enabling.
5. **CI runner label.** `.github/workflows/ci.yml` uses `runs-on: macos-26`.
   That label has not been verified on GitHub-hosted runners. The workflow is
   unchanged.
6. **Not verified:** Developer ID signing, notarization and stapling, Sparkle
   update delivery from a real appcast, privileged helper authorization against
   the live daemon, live advanced-metric sampling, VoiceOver and keyboard-only
   operation, the icon in the Dock and About panel, and long-running
   performance and memory behavior.
7. **Pre-release history.** Builds before this release recorded per-app CPU
   seconds in the wrong unit. Reset App History before relying on those values.

A successful compile or a focused automated test does not establish any of the
unverified items above.
