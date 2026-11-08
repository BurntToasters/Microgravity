# Implementation status

Latest status for Microgravity 0.1.2 on branch `next-0.1.2`, checked 2026-11-08
(see Latest results below). The 0.1.0 gate record from 2026-11-07 is kept under
Earlier record. It ran on macOS 27.2 build 26B123 (arm64 virtual machine), Xcode
27.2 (27B52), Node.js 26.13.0, against commit `ec836a6` plus the uncommitted
`gate/0.1.0` changes. It was run from an isolated worktree outside `~/Documents`
whose changed-file bytes matched the canonical tree. Re-run the full release
gates from a clean canonical checkout before tagging.

Intended behavior is in [UI acceptance](UI_ACCEPTANCE.md). Collector, history,
and process-action regressions are in [core failure cases](FAILURE_CASES_CORE.md).
The release procedure and the 0.1.0 UI gate are in [RELEASING.md](RELEASING.md).

## Verification

### Latest results (2026-11-08, branch `next-0.1.2`)

| Gate | Command | Result |
| --- | --- | --- |
| Core XCTest | unsigned Core XCTest | 286 executed; 0 failed. Run on commit `f8b6a68` plus test fixes that were later committed. |
| Signed UI XCTest | `-only-testing:MicrogravityUITests`, `CODE_SIGN_IDENTITY="Apple Development"`, `DEVELOPMENT_TEAM=FYJZP8B2KG`, from the `~/Documents` checkout | 23 executed: 21 passed, 2 failed. Both failures were stale assertions after 0.1.1 (`testHistoryShowsGapsAndRequiresConfirmationToReset`, `testDetailsIsFlatAndShowsUnavailableMetricsExplicitly`). Both were fixed and passed on rerun. The full UI suite was not rerun after the fixes. |
| Runtime diagnostics | same signed UI run | 23 occurrences of "This method should not be called on the main thread as it may lead to UI unresponsiveness." Unresolved; not a zero-diagnostics pass. See Known gaps, item 4. |
| Composite `npm run test:all` | not run | No release proof recorded for these results. |

### Earlier record: 0.1.0 gates (2026-11-07)

| Gate | Command | Result |
| --- | --- | --- |
| Workspace validation | `npm run validate` | pass |
| Project and version sync | `npm run project:sync -- --check`, `npm run sync-version -- --check` | pass |
| Node tests | `npm run test:node` | 32 passed, 0 failed, 0 skipped |
| Core XCTest | signed composite run (`npm run test:all`) | 220 executed; 0 failed; 0 skipped |
| Debug build | `npm run build:debug` | pass; strict Debug build |
| Release smoke | `npm run build:release-smoke` | pass (unsigned universal Release compile) |
| Bundle icon check | `validateWorkspace({ bundle })` against the Debug app | pass in an earlier verification checkout; not re-run for this change set |
| Strict concurrency diagnostics | strict Debug build | pass |
| Runtime diagnostics | signed composite run, unified log attribution | 23 occurrences of "This method should not be called on the main thread as it may lead to UI unresponsiveness." One per UI test that launches the app; 0 from Core tests. Not attributed to Microgravity source frames. Unresolved and not suppressed; not a zero-diagnostics pass. See Known gaps. |
| Signed UI XCTest | signed composite run (UI part of `npm run test:all`) | 23 executed; 0 failed; 0 skipped |
| Composite `npm run test:all` | `MICROGRAVITY_UI_SIGNING_IDENTITY='Apple Development' MICROGRAVITY_UI_TEAM_ID=FYJZP8B2KG npm run test:all` | exit 0; Passed; 243 executed (Core 220 + UI 23); 0 failed; 0 skipped; 0 expected failures. Reported `dirty worktree; no reusable release proof recorded`. Local result bundle: `DerivedData/Evidence/gate-2026-11-07/final-test-all.xcresult` (gitignored, not committed). |
| Fixture preferences | host Preferences audit after the final suite | 0 nonempty `Microgravity.UITests.*` domains; 0 UI-fixture keys in `run.rosie.microgravity.plist`. Two `NSWindow Frame WindowTests-<UUID>` keys from an older Core run on a 2560 × 1297 display remain; not touched. |
| Visual matrix | `testVisualAcceptanceCapturesAllPagesAtBothSizesAndAppearances` (signed composite run) | 48 captures: 8 pages (Processes, Performance, App History, Startup, Users, Details, Services, Settings) × 3 appearances (System, Light, Dark) × 2 sizes. All 24 default captures measured 1280 × 820 pt (2560 × 1640 px). All 24 minimum captures measured 960 × 600 pt (1920 × 1200 px). Display scale 2.00. Appearance was selected through the Settings Appearance pop-up and verified. The runner's effective appearance was darkAqua, so System matches Dark on this host. Minimum size is reached by relaunching with the DEBUG, fixture-only `--ui-test-window-content-size=960x600` flag, which uses the production content-size path. Frames are measured, not faked. Manifest: `DerivedData/Evidence/gate-2026-11-07/capture-manifest.csv`. |
| History gap captures | `testHistoryGapVisualCapturesAtDefaultAndMinimumSizes` | 2 captures (default and minimum) of the `--ui-test-history-gap` App History state |
| Capture review | manager review of all captures | All 48 matrix captures and 2 history-gap captures reviewed (contact sheets and full-resolution crops). Known open visual issues are listed under Known gaps. Not a human release review. |
| Manual UI checklist | [RELEASING.md](RELEASING.md) | pending: see Known gaps, item 2 |
| Hosted CI | `.github/workflows/ci.yml` | not run. Blocked: the repository owner's GitHub Actions minutes are exhausted for this month. Not a failure. `macos-26` availability is confirmed by GitHub docs below. |

Changes verified in the 2026-11-07 run. Each has Core regression tests:

- Settings helper caption ("Lets you quit processes owned by other standard
  users. System and root processes stay protected.") wraps instead of
  truncating.
- App History partial totals show a compact `≥ <value>` (for example
  `≥ 108.0 s`). The full text (`Measured 108.0 s; partial — 1 gap(s); actual
  total may be higher`) is in the tooltip and accessibility label. Unavailable
  still shows "Unavailable", never zero. Numeric sorting is unchanged.
- Details showed values from the wrong columns in six columns (CPU showed the
  executable path, and Executable path showed GPU). Those columns also sorted by
  the wrong keys. Row values now follow the column order, and a DEBUG assertion
  checks that value and sort-key counts match the columns.
- Right-aligned numeric columns (Users, Details, and the App History outline)
  now trail-align their values under right-aligned headers.
- Settings is top-anchored with natural card heights. It was bottom-anchored,
  which opened scrolled to the bottom at 960 × 600.
- Fixture launches no longer read or write Details, Startup, or Services table
  column autosave in the real app preferences domain.

Drag-resize is not automated. On this VM host, XCUITest-synthesized drags never
changed window frames. Nine edge and corner resize drags and a title-bar move
all left the frame at 1280 × 820. The earlier minimum-size failure came from
this environment limit, not from an app resize bug. Window minimum and geometry
are covered by Core `WindowTests`: content minimum 960 × 600, resizable style,
exact minimum and custom 1100 × 700 frames stable across sidebar selection,
the showPage menu action, and appearance changes, re-expansion from minimum,
and the fixture size-flag parser. A manual drag-resize check is still needed.

Four app-only screenshots are committed under [`screenshots/`](screenshots/).
Processes and Performance (dark) are from an earlier signed test run. The
Settings images (Light and Dark) are the default-size captures from the final
visual matrix run, downscaled to 2080 px wide. All four show fixture states. No
manual VoiceOver or live controlled-process sheet review is claimed.

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
  identity. The process table is read with one `KERN_PROC_ALL` sysctl, capped at
  16,384 entries. The cap, sysctl failures, and identity omissions are reported
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
- Advanced metrics run through the helper (see [ADVANCED_METRICS.md](ADVANCED_METRICS.md)). Process identities for helper network samples come from the `KERN_PROC_ALL` table, which includes other users' processes. Refreshes retry immediately when the app becomes active.
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
- App History is one application-to-day outline. Partial totals display as
  `≥ <value>`, with the full measurement detail in the tooltip.
- Startup and Services are read-only, with status, kind labels, a coverage
  banner, Reveal in Finder, and Open Login Items Settings.
- Users shows a current-user badge beside the name in the User column; sorting
  uses the bare name. Details accepts cross-page selection by full process
  identity.
- Settings is a form for appearance, interval, pause, history reset, helper,
  login item, and updates. Its helper caption wraps.
- Force Quit and Reset History confirmations are window sheets.
- App icon: `Info.plist` declares `CFBundleIconName` as `microgravity`, and the
  app target sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `microgravity`. The
  built Debug app contains the icon in `Assets.car` and a `microgravity.icns`
  fallback. `scripts/validate.mjs` checks both. The icon has not been viewed in
  the Dock, About panel, or Force Quit dialog.

## Known gaps

1. **Release proof.** The 2026-11-07 signed composite gate exited 0 (243 tests,
   0 failed, 0 skipped), but `test:all` reported a dirty worktree. No reusable
   release proof exists for that run, or for the 2026-11-08 results, which were
   not run through `test:all`. `release:prepare` records one from a clean
   canonical checkout; it runs `test:all -- --skip-ui` unless
   `MICROGRAVITY_RELEASE_UI_TESTS=1` (see
   [RELEASING.md](RELEASING.md#ui-tests-and-the-release-gate)). An older
   `--skip-ui` run recorded on 2026-11-08 (220 Core tests, 0 failed) completed
   from the `~/Documents` checkout; the 286-test Core result above supersedes its
   count. The full UI suite can hang before connecting from a
   checkout there, because the unsigned test host triggers a macOS Documents
   privacy prompt while loading Sparkle.framework; run it from a checkout
   outside `~/Documents`.
2. **Manual UI review.** Pending: VoiceOver spot check; keyboard shortcuts, menu,
   toolbar, and sidebar toggle; manual drag-resize to 960 × 600 and back; live
   Force Quit and Reset History sheets on a tester-created throwaway process and
   disposable history; last-window-close and reopen frame restore on a real
   launch; icon in the Dock, About panel, and Force Quit dialog; live helper
   setup, removal, and protected-process rejection; live login item; and
   long-running live metrics and history.
3. **Known open visual issues** (non-blocking, cosmetic):
   a. Fixed in 0.1.1: Settings form labels share one column width across cards,
   and the Appearance row no longer moves when its value changes (Core test
   `testSettingsLabelsLineUpAcrossCardsAndStayPutWhenAppearanceChanges`).
   b. Details "Disk R / W" values middle-truncate at the default column width.
   The column is resizable. The full value is in the accessibility label.
   c. Wide tables (Processes, App History, Details, inventory) scroll
   horizontally inside the table at minimum width. The page body does not.
4. **Runtime warnings (unresolved).** The main-thread warning above appears once
   per UI test that launches the app, at the runner's first accessibility
   snapshot. Attribution from controlled split tests and unified log: AppKit
   LSSharedFileList recent-items population on the main thread, then
   LaunchServices walking registered app records (many stale DerivedData
   `Microgravity.app` copies), then Security `SecKeyVerifySignature` and
   `SecTrustEvaluateIfNecessary`, then a `com.apple.runtime-issues:Security`
   fault. No Microgravity source frame is involved, and helper signature
   validation is not involved (fixture mode uses `UnavailableSystemIntegrationAPI`).
   Control runs: a UI test without app launch, 0 warnings; a Finder query only,
   0; a TextEdit launch and query, 0. The cause is external to app code. It is
   not suppressed, and this is not a zero-diagnostics pass. Unregistering stale
   app copies from LaunchServices may mitigate it. That was not applied.
5. **CI.** GitHub lists `macos-26` as a hosted runner, including arm64, and
   announced its general availability on 2026-02-26 ([runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job), [announcement](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)). The workflow has not run for this tree. Hosted CI is blocked because the repository owner's GitHub Actions minutes are exhausted for this month.
6. **Not verified:** Developer ID signing, notarization and stapling, Sparkle
   update delivery from a real appcast, privileged helper authorization against
   the live daemon, live advanced-metric sampling, the icon in the Dock and About
   panel, and long-running performance and memory behavior.
7. **Pre-release history.** Builds before this release recorded per-app CPU
   seconds in the wrong unit. Reset App History before relying on those values.

A successful compile or a focused automated test does not establish any of the
unverified items above.
