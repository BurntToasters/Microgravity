# Implementation status

Last verified: 2026-11-05 on macOS 27.2 (Build 26B123), Xcode 27.2
(Build 27B52), arm64, Node.js 26.13.0, in a disposable macOS VM.

Microgravity has native AppKit monitoring surfaces backed by the local collector,
with explicit unavailable and incomplete states. Optional helper, login-item, and
updater controls depend on platform configuration and approval. See
[UI acceptance](UI_ACCEPTANCE.md) for intended behavior and
[core failure cases](FAILURE_CASES_CORE.md) for collector, history, and action
regressions.

## Verified on the VM

| Gate | Command | Result |
| --- | --- | --- |
| Repository validation | `npm run validate` | pass, exit 0 |
| Node tests | `npm run test:node` | 19 passed, 0 failed |
| Debug build | `npm run build:debug` | pass; unsigned development app at `DerivedData/Build/Build/Products/Debug/Microgravity.app` |
| Release smoke build | `npm run build:release-smoke` | pass; unsigned universal (`arm64 x86_64`) Release compile |
| Core XCTest | `-only-testing:MicrogravityCoreTests` | 59 passed, 0 failed; `DerivedData/TestResults/Final-Core3.xcresult` |
| UI XCTest | signed `-only-testing:MicrogravityUITests` | **not passing**: 13 executed, interaction delivery failures described below; signed `build-for-testing` succeeds |

The Debug configuration disables the hardened runtime so the ad-hoc development
app can load the embedded Sparkle framework without a Team ID mismatch. The
Release configuration keeps the hardened runtime.

## UI test status on the VM

Automation Mode was configured with the administrator-approved
`enable-automationmode-without-authentication` command. The machine now reports
`This device DOES NOT REQUIRE user authentication to enable Automation Mode.`,
but `automationmodetool` still reports `Automation Mode is disabled.`; this
Xcode build exposes no other enable command, so TASK.md's expected
`Automation Mode is enabled.` state was not reached.

The signed UI suite runs and is past initialization, but synthesized
interactions do not reach the app:

- the app window is present and, after an explicit activation retry, reports
  `NSApp.isActive == true` with a key main window and no modal panel;
- taps produce only `mouseEntered` at the window; no `leftMouseDown` /
  `leftMouseUp` is delivered;
- the disclosure button's action never fires, no table selection changes are
  reported, and a right-click never opens the context menu, across unrelated
  controls (sidebar navigation, table rows, buttons);
- failures are therefore uniform interaction-delivery failures, not
  process-table logic failures.

A prior cold-start pattern (`Application ... does not have a process ID`) and
`not foreground and does not allow background interaction` errors were reduced
by the test-harness changes below, but the remaining delivery failure persists.

## Uncommitted changes

- `Sources/UI/ProcessesViewController.swift` — `ProcessNameCellView` now stores
  the group's `ProcessIdentity`; `toggleGroup(_:)` resolves the group by walking
  up from the tapped button to that cell (with the original row lookup as a
  fallback) because `tableView.row(for:)` returns `-1` for buttons nested inside
  cell views on current macOS. The name field's accessibility identifier is the
  row identity (`process.group.<slug>` / `process.row.<pid>`) that the UI tests
  target. This is a product behavior change, not a test weakening.
- `Tests/UITests/MicrogravityUITests.swift` — `launchFixture()` forwards
  `XCTestConfigurationFilePath` into the app launch environment (the documented
  fixture gate requires both `--ui-test-fixtures` and an XCTest marker) and
  retries `activate()` until the app is foreground, removing the "not
  foreground" tap refusal. No assertion was weakened or removed.
- `TEST_RESULTS.md` — full evidence, commands, counts, and `.xcresult` paths.

The same uncommitted tree also contains the code-audit remediation: CI gate
split and self-hosted UI documentation, `gh` token allowlist, single-use helper
authorization, minimal termination payload, history WAL/batched upserts/
column-aware migration and publish-race fix, partial group aggregates,
bundle-ID history keys, bundle metadata cache, truthful discovery coverage,
case-insensitive plist scanning, cached page controllers, helper-removal gating,
and documented CPU normalization. Details are in `TEST_RESULTS.md`.

## Remaining verification

- the 13 native UI tests, blocked by synthesized-interaction delivery in this VM;
- signed Developer ID distribution, notarization, and stapling;
- Sparkle update delivery from a real appcast;
- privileged helper authorization against the live daemon;
- VoiceOver and full keyboard-only operation;
- long-running real-world performance and memory behavior;
- light/dark appearance and window resizing on physical displays.

No security or signing shortcut was used: SIP, Gatekeeper, and TCC were left
untouched, and only the Apple Development identity was used for test signing.
A successful compile or focused automated test does not establish any of the
unverified items above. Release requirements are tracked in
[RELEASING.md](RELEASING.md).
