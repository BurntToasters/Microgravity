# Implementation status

Status for Microgravity 0.1.0, checked 2026-11-07 on macOS 27.2 (arm64), Xcode
27.2 (27B52), Node.js 26.13.0. Results are for changes on top of commit
`af1359c`. Re-run the full release gates before tagging.

Intended behavior is in [UI acceptance](UI_ACCEPTANCE.md). Collector, history,
and process-action regressions are in [core failure cases](FAILURE_CASES_CORE.md).
The release procedure and the 0.1.0 UI gate are in [RELEASING.md](RELEASING.md).

## Verification

| Gate | Command | Result |
| --- | --- | --- |
| Workspace validation | `npm run validate` | pass |
| Project and version sync | `npm run project:sync -- --check`, `npm run sync-version -- --check` | pass |
| Node tests | `npm run test:node` | 32 passed, 0 failed |
| Core XCTest | Core command in [RELEASING.md](RELEASING.md) | 207 passed in latest composite run; 0 skipped |
| Debug build | `npm run build:debug` | pass after app cleanup change; strict Debug build |
| Release smoke | `npm run build:release-smoke` | pass after app cleanup change (unsigned universal Release compile) |
| Bundle icon check | `validateWorkspace({ bundle })` against the Debug app | pass in verification checkout |
| Strict concurrency diagnostics | strict Debug build | pass |
| Runtime diagnostics | final composite XCTest audit | 22 runtime warnings remain. Helper validation now runs in the background and the focused Core trace warning is resolved; a separate UI Security callback warning remains. |
| Signed UI XCTest | signed command in [RELEASING.md](RELEASING.md) | 22 executed: 21 passed, 1 failed; 0 skipped. Three assertions failed in the minimum-size visual test. |
| Composite `npm run test:all` | manager verification checkout based on `af1359c` | 229 executed (Core 207 + UI 22): 228 passed, 1 failed, 0 skipped. Result bundle: `/private/tmp/microgravity-final-audit-6nwsxljc/final-test-all.xcresult` |
| Fixture preferences | external host Preferences audit after suite | 0 nonempty `Microgravity.UITests.*` domains and 0 fixture autosave keys |
| Screenshot review | latest visual XCTest attachments | 24 default-size PNGs at 2,560 × 1,640 pixels; no minimum-size images. Manifest: `/private/tmp/microgravity-final-audit-6nwsxljc/attachments/manifest.json`; measurements: `/private/tmp/microgravity-final-audit-6nwsxljc/default-captures.json`. Settings Dark inspection found truncated helper text; History CPU partial lower-bound readability remains unresolved. Not a full visual pass. |
| Manual UI checklist | [RELEASING.md](RELEASING.md) | pending: all-page visual review at both sizes, VoiceOver, and manual controlled-process Force Quit / Reset History sheet checks |
| Hosted CI | `.github/workflows/ci.yml` | not run; `macos-26` availability confirmed by GitHub docs below |

An earlier signed gate passed 224 tests on the app-cleanup patch. That result is
superseded for the current visual-coverage patch: the latest manager composite
run executed 229 tests, with 228 passing and the visual minimum-size test
failing. Its window remained at 1,280 × 820 instead of resizing to 960 × 600;
three assertions failed in that one test. The run produced 24 default-size
screenshots (all 2,560 × 1,640 pixels) and no minimum-size images. The Settings
Dark capture inspected by the manager truncates the helper explanation, and the
History CPU partial lower bound still needs to remain readable. Do not treat
the older 224-test result or these partial captures as release evidence.

The current run also confirms that fixture refresh, full-identity selection,
native group expansion persistence, numeric history sorting, and app-owned
test-defaults cleanup tests pass. An external host Preferences audit of the
accepted cleanup patch found zero nonempty fixture domains and zero fixture
autosave keys. The source worktree is dirty and the latest composite gate failed,
so there is no reusable release proof. Automation Mode was not sampled during
the tests. The final composite audit recorded 22 runtime warnings; helper
validation now runs in the background and the focused Core trace warning is
resolved, but a separate UI Security callback warning remains.

Earlier accessibility output reported a 12,784 pt Processes outline. A later
automated matrix produced 24 default-size captures across eight pages and three
appearances, but no minimum-size captures because the resize interaction did
not change the measured window frame. Only selected captures were inspected;
the Settings Dark helper line truncates. Automated appearance selection does
not establish full visual acceptance.

Four app-only screenshots from an earlier signed test run are committed under
[`screenshots/`](screenshots/): Processes, Performance, and Settings in Light
and Dark appearance. They show fixture states. The latest default-size matrix
attachments are in the result bundle above; it did not produce minimum-size
images. No manual VoiceOver or live controlled-process sheet review is claimed.

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

1. **Release proof.** The latest 229-test composite gate failed one UI test in
   a temporary verification checkout based on `af1359c`; the source worktree is
   dirty. Run `release:prepare` only after the full gate passes from a clean
   canonical checkout; see
   [RELEASING.md](RELEASING.md#ui-tests-and-the-hard-release-gate).
2. **Manual UI review.** The automated matrix captured 24 default-size images
   and zero minimum-size images. The window resize stayed at 1,280 × 820; the
   Settings Dark helper text was visibly truncated, and History's partial CPU
   lower bound still needs readable display. All-page review, VoiceOver, and
   controlled-process Force Quit / Reset History sheet behavior remain pending.
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
