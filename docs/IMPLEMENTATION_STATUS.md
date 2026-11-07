# Implementation status

Status for Microgravity 0.1.0, checked 2026-11-07 on macOS 27.2 (arm64), Xcode
27.2 (27B52), Node.js 26.13.0. Results are for the working tree on top of commit
`f54530e`. Re-run the gates before tagging.

Intended behavior is in [UI acceptance](UI_ACCEPTANCE.md). Collector, history,
and process-action regressions are in [core failure cases](FAILURE_CASES_CORE.md).
The release procedure and the 0.1.0 UI gate are in [RELEASING.md](RELEASING.md).

## Verification

| Gate | Command | Result |
| --- | --- | --- |
| Workspace validation | `npm run validate` | pass |
| Project and version sync | `npm run project:sync -- --check`, `npm run sync-version -- --check` | pass |
| Node tests | `npm run test:node` | 32 passed, 0 failed |
| Core XCTest | Core command in [RELEASING.md](RELEASING.md) | 205 executed, 0 failures, 0 skipped |
| Debug build | `npm run build:debug` | pass (unsigned development app) |
| Release smoke | `npm run build:release-smoke` | pass (unsigned universal Release compile) |
| Bundle icon check | `validateWorkspace({ bundle })` against the Debug app | pass |
| Strict concurrency diagnostics | strict Debug build from concurrency worker | pass; one vendored Sparkle Objective-C include-case warning |
| Signed UI XCTest | signed command in [RELEASING.md](RELEASING.md) | final full run: 18 executed, 15 passed, 3 failed, 0 skipped; focused selection/search/sort: 1 passed |
| Screenshot review | captures from signed UI XCTest | four app-only crops committed; partial visual inspection only |
| Manual UI checklist | [RELEASING.md](RELEASING.md) | not done; 1280 × 820 / 960 × 600 review, VoiceOver, and manual sheet proof remain pending |
| Hosted CI | `.github/workflows/ci.yml` | not run from this tree; `macos-26` availability confirmed by GitHub docs below |

The final signed UI run on 2026-11-07 passed 15 of 18 tests. The three failures
are two snapshot-refresh waits and one history numeric-sort order assertion;
details are in [RELEASING.md](RELEASING.md#ui-tests-and-the-hard-release-gate).
Automation Mode reported disabled immediately before and after runs; a poll
during the final run reported enabled. The suite performed real native clicks
while enabled. These three failures did not arise from a blanket automation
block.

An earlier accessibility snapshot reported a 12,784 pt Processes outline. With
per-test fixture defaults and a unique process-outline autosave key, the signed
run expanded groups and preserved expansion across relaunch. Its screenshot at
the restored 1,040 × 820 window shows the process table within the page, with a
horizontal table scroller. A fresh 1,280 × 820 window and minimum-size layout
have not been visually checked, so this does not establish full layout
acceptance.

Four app-only screenshots from the signed test run are committed under
[`screenshots/`](screenshots/): Processes, Performance, and Settings in Light
and Dark appearance. These show fixture states. Captures also exist in the
`.xcresult` bundle for Details, App History, Startup, Services, and Users, but
only the four committed crops were visually inspected. No manual VoiceOver or
sheet review is claimed.

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
  Group expansion persists by full PID-plus-start-time identity. Show in Details
  requests the same full identity and selects it only while that identity exists.
- Performance has a metric rail with sparklines, a detail graph with grid, axis
  labels, gap markers, a time-window picker, per-core activity, a swap capacity
  bar, and a memory pressure timeline.
- App History is one application-to-day outline.
- Startup and Services are read-only, with status, kind labels, a coverage
  banner, Reveal in Finder, and Open Login Items Settings.
- Users shows a current-user badge beside the name in the User column; sorting
  uses the bare name. Details accepts cross-page selection by full process
  identity.
- Settings is a form for appearance, interval, pause, history reset, helper,
  login item, and updates.
- Force Quit and Reset History confirmations are window sheets.
- App icon: `Info.plist` declares `CFBundleIconName` as `microgravity`, and the
  app target sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `microgravity`. The
  built Debug app contains the icon in `Assets.car` and a `microgravity.icns`
  fallback. `scripts/validate.mjs` checks both. The icon has not been viewed in
  the Dock, About panel, or Force Quit dialog.

## Known gaps

1. **UI hard gate.** `npm run test:all` includes UI XCTest and `release:prepare`
   depends on it. Current signed UI runs are failing; see
   [RELEASING.md](RELEASING.md#ui-tests-and-the-hard-release-gate).
2. **Manual UI review.** Four fixture screenshots are committed and partially
   inspected. Light, dark, and System appearances across all pages at 1280 × 820
   and 960 × 600, VoiceOver, and manual Force Quit / Reset History sheet behavior
   remain pending.
3. **CI.** GitHub lists `macos-26` as a hosted runner, including arm64, and
   announced its general availability on 2026-02-26 ([runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job), [announcement](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)). The workflow itself has not run from this tree.
4. **Not verified:** Developer ID signing, notarization and stapling, Sparkle
   update delivery from a real appcast, privileged helper authorization against
   the live daemon, live advanced-metric sampling, the icon in the Dock and About
   panel, and long-running performance and memory behavior.
5. **Pre-release history.** Builds before this release recorded per-app CPU
   seconds in the wrong unit. Reset App History before relying on those values.

A successful compile or a focused automated test does not establish any of the
unverified items above.
