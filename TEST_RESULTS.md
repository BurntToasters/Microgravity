# Test results — Microgravity verification on the VM

Date: 2026-11-05
Host: macOS 27.2 (Build 26B123), Xcode 27.2 (Build 27B52), arm64, Node.js 26.13.0
VM: disposable macOS VM, GUI session logged in as `dev`

## Audit remediation update — 2026-11-05

Audit fixes were implemented across collector caching and transient-failure handling, helper
termination preflight, table reuse/sorting/selection, performance graph reuse and
pause gaps, and UTC history handling with cached SQLite baselines and throttled
history queries. Project sync, version sync, validation, Node tests (19/19),
debug build, universal release-smoke build, and Core XCTest (71/71) passed. Core
result bundle: `DerivedData/TestResults/Audit-Core-20261105.xcresult`.

The initial signed UI run, `DerivedData/TestResults/Audit-UI-20261105.xcresult`,
ran 15 tests: 1 passed, 14 failed, with 52 assertions. Automation Mode is
disabled and enabling it requires user authentication. UI extraction also found
that AppKit exposes synthetic rows without row-view identifiers despite unique
labels and toggles. Tests now resolve native rows through their unique labels.

The final focused signed run,
`DerivedData/TestResults/Audit-UI-Focused-20261105.xcresult`, compiled successfully
and ran three tests. The interaction-free test for distinct native rows and unique
labels and disclosure identifiers passed. The expansion and context-menu tests
failed with three assertions: synthesized disclosure clicks did not expand the
groups, leaving the expected child rows absent. The complete UI suite remains
unverified after the query correction; interaction validation requires working
GUI automation. No security or signing configuration was changed.

The sections below preserve the earlier verification record and its original
test counts; the results above describe this audit remediation.

## Outcome summary

| Gate | Result |
| --- | --- |
| `npm run validate` | **pass** |
| `npm run test:node` | **19 passed, 0 failed** |
| `npm run build:debug` | **pass** |
| `npm run build:release-smoke` | **pass** |
| Core XCTest (`-only-testing:MicrogravityCoreTests`) | **59 passed, 0 failed** |
| Signed UI XCTest (`-only-testing:MicrogravityUITests`) | **not passing** — 13 tests run; every failure is an interaction-delivery failure (details below) |
| Signed `npm run test:all` | blocked by the same UI issue |

The product, audit-remediation, and test-harness fixes described below are
present, uncommitted. Everything except the UI suite is verified green.

## Preconditions

```
$ sw_vers
ProductName:		macOS
ProductVersion:		27.2
BuildVersion:		26B123

$ xcodebuild -version
Xcode 27.2
Build version 27B52

$ node --version
v26.13.0

$ uname -m
arm64

$ security find-identity -v -p codesigning
  1) 51337A39536E2955882B915F9B17CD5BE1981B75 "Apple Development: Johann Smith (W22N3XDGQU)"
  2) BE5A5E3B97A3145A2700E8F6F3AAC066F5A19649 "Developer ID Application: Johann Smith (FYJZP8B2KG)"
  3) F491732F7C4419E13F50E733586BE211630A253E "Apple Distribution: Johann Smith (FYJZP8B2KG)"
     3 valid identities found
```

Automation Mode: `enable-automationmode-without-authentication` was run with
administrator approval and the machine reports
`This device DOES NOT REQUIRE user authentication to enable Automation Mode.`,
but `automationmodetool` still reports `Automation Mode is disabled.` The CLI has
no other enable command on this build, so the "Automation Mode is enabled"
precondition in TASK.md §2 was never reached.

## Non-UI gates

```
$ npm run validate
validate: ok                                  # exit 0

$ npm run test:node
ℹ tests 19
ℹ pass 19
ℹ fail 0                                     # exit 0

$ npm run build:debug
build:debug: ok (unsigned development app)    # exit 0

$ npm run build:release-smoke
build:release-smoke: ok (unsigned universal Release compile)   # exit 0
```

Core XCTest (TASK.md §4 command, `CODE_SIGNING_ALLOWED=NO`, after the audit
remediation):

```
Executed 59 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

Result bundle: `DerivedData/TestResults/Final-Core3.xcresult`

Note: two earlier Core attempts failed with "The test runner hung before
establishing connection" — a stale `testmanagerd` from the long verification
session, not a code failure. `killall testmanagerd` followed by a rerun passed
59/59.

## UI XCTest — current state and evidence

Full signed command from TASK.md §5 (`CODE_SIGN_IDENTITY="Apple Development"`,
`DEVELOPMENT_TEAM=FYJZP8B2KG`, `SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO`) was run with
no parallel testing:

```
Executed 13 tests, with 35 failures (0 unexpected)
** TEST FAILED **   # exit 65
```

Result bundle: `DerivedData/TestResults/Microgravity-UI.xcresult`

Distinct failure classes observed:

1. `Failed to tap ... is not foreground and does not allow background interaction`
2. Taps reported as performed but no app-side effect: the disclosure toggle never
   expands the group and no `process.row.410` element appears.
3. `Application 'run.rosie.microgravity' does not have a process ID` on first
   launches after a cold runner start.

Instrumented diagnostics, run against the real app under the test runner:

- The app window is present in the AX hierarchy, and after an explicit
  activation retry loop the app reports `NSApp.isActive == true` and
  `isKeyWindow == true` for the whole test.
- `XCUIElement.tap()` produces only `mouseEntered` events at the window; no
  `leftMouseDown`/`leftMouseUp` is ever delivered (`sendEvent` trace).
- The disclosure button's target/action never fires, no row selection change is
  reported, and a right-click on the group row never opens the context menu.
- A plain `NSWindow`-level log showed the key window is the normal main window
  (no modal panel/sheet).

So the failures are consistent across unrelated controls (sidebar navigation,
table rows, buttons) and occur even though the app is active and key. This is an
interaction-delivery limitation of this VM/runner combination, not a regression
in the process-table logic: the assertions that can run (element existence, AX
identifiers, fixture data) all resolve correctly once the fixture marker is
supplied.

## Uncommitted changes

### 1. `Sources/UI/ProcessesViewController.swift` (product)

```diff
@@ switch item {
             case .group(let group):
                 cell.configure(text: group.title, accessibilityID: item.accessibilityID, group: true,
                                expanded: expandedGroups.contains(group.id),
                                toggleIdentifier: "process.group.toggle.\(slug(group.title))",
-                               target: self, action: #selector(toggleGroup(_:)))
+                               groupIdentity: group.id, target: self, action: #selector(toggleGroup(_:)))
             case .process(let process):
                 cell.configure(text: process.name, accessibilityID: item.accessibilityID, group: false, expanded: false,
-                               toggleIdentifier: nil, target: nil, action: nil)
+                               toggleIdentifier: nil, groupIdentity: nil, target: nil, action: nil)
@@ toggleGroup(_:)
+        // Walk up to the containing cell view; `tableView.row(for:)` returns
+        // -1 for buttons nested inside table cell views on current macOS.
+        var view: NSView? = sender
+        while let current = view {
+            if let cell = current as? ProcessNameCellView, let identity = cell.groupIdentity {
+                if expandedGroups.contains(identity) {
+                    expandedGroups.remove(identity)
+                } else {
+                    expandedGroups.insert(identity)
+                }
+                rebuildRows(preservingSelection: true)
+                return
+            }
+            view = current.superview
+        }
         let row = tableView.row(for: sender)
@@ ProcessNameCellView
+    private(set) var groupIdentity: ProcessIdentity?
+
     func configure(..., groupIdentity: ProcessIdentity?, target: AnyObject?, action: Selector?) {
+        self.groupIdentity = group ? groupIdentity : nil
         nameField.stringValue = text
-        nameField.setAccessibilityIdentifier(accessibilityID + ".name")
+        nameField.setAccessibilityIdentifier(accessibilityID)
```

Rationale: `tableView.row(for:)` returns `-1` for buttons nested inside
`NSTableCellView`s on current macOS, so the disclosure action could not resolve
its row; binding the identity to the cell removes that dependency. The name
field now carries the row's exact accessibility identifier, which is what the UI
tests query (`process.group.<slug>`, `process.row.<pid>`).

### 2. `Tests/UITests/MicrogravityUITests.swift` (test harness)

```diff
     private func launchFixture(arguments: [String] = []) -> XCUIApplication {
         let app = XCUIApplication()
         app.launchArguments = ["--ui-test-fixtures"] + arguments
+        app.launchEnvironment["XCTestConfigurationFilePath"] =
+            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "MicrogravityUITests.xctest"
         app.launch()
+        // The XCTest runner keeps focus on macOS; without an explicit
+        // activation XCUITest refuses taps ("not foreground").
+        for _ in 0..<50 where app.state != .runningForeground {
+            app.activate()
+            usleep(100_000)
+        }
         XCTAssertTrue(element("navigation.item.processes", in: app).waitForExistence(timeout: 5))
         return app
     }
```

Rationale: `AppComposition.isFixtureUITest` requires both `--ui-test-fixtures`
and an XCTest environment marker, per `docs/UI_ACCEPTANCE.md`; without the marker
the app runs against live data and every fixture assertion fails. Supplying the
marker is required by the documented fixture gate and does not weaken any
assertion. The activation retry removes the explicit
"not foreground" tap refusal.

### 3. `docs/IMPLEMENTATION_STATUS.md`

Updated with the VM results above.

## Code audit remediation (2026-11-05)

A full audit was run and its findings were fixed in the same uncommitted tree:

- CI: hosted macOS now runs validate, Node, unsigned Core XCTest, Debug build,
  and Release-smoke; the signed UI gate is documented as mandatory on a
  dedicated logged-in GUI runner instead of failing hosted CI.
- Release: `gh` helpers receive `GH_TOKEN`/`GITHUB_TOKEN`; no other child
  process does.
- Privileged helper: authorization external forms are single-use (SHA-256,
  10-minute expiry, 256-entry bound), consumed only after the target passes
  double identity validation; the wire target carries identity only.
- History: WAL + `synchronous=NORMAL`, prepared statements reused for all
  application rows per tick, column-aware v1/v2 migration with fail-closed
  unknown schemas, negative stored values surface as unavailable, and the
  publish race after pause/stop/reset is closed.
- Collector: partial group aggregates sum available members with a partial
  detail, bundle-ID history keys survive moves/reinstalls, and bundle metadata
  is cached with a 256-entry bound.
- Discovery: coverage reflects real enumeration/parse failures, `.plist`
  matching is case-insensitive, and known launchd-state limitations no longer
  mark otherwise successful scans as incomplete.
- UI: page controllers are cached so search/selection/scroll survive sidebar
  navigation; CPU normalization is documented in `docs/UI_ACCEPTANCE.md`.
- Settings: a registered helper can be removed even when its handshake is
  failing.

Verification after these changes: `validate`, 19/19 Node, Debug build,
Release-smoke build, 59/59 Core XCTest, and signed UI `build-for-testing` all
pass. The UI runtime suite remains blocked by the VM interaction-delivery issue
described above.

## Remaining verification

- 13 signed UI tests: blocked by synthesized-interaction delivery in this VM
  (app is active/key, yet no mouse-down, no selection, no button action).
- Developer ID signing, notarization, stapling.
- Sparkle update delivery from a real appcast.
- Privileged helper authorization against the live daemon.
- VoiceOver and full keyboard-only operation.
- Long-running real-world performance and memory behavior.
- Light/dark appearance and window resizing on physical displays.

No security or signing shortcut was used: SIP, Gatekeeper, and TCC were left
untouched, and only the Apple Development identity was used for test signing.

## Reproduction commands

```sh
# Core
xcodebuild -project Microgravity.xcodeproj -scheme Test -configuration Debug \
  -derivedDataPath "$PWD/DerivedData/Tests" \
  -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" \
  -packageCachePath "$PWD/DerivedData/PackageCache" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -resultBundlePath "$PWD/DerivedData/TestResults/Microgravity-Core.xcresult" \
  -only-testing:MicrogravityCoreTests test \
  CODE_SIGNING_ALLOWED=NO SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO

# UI (signed)
xcodebuild -project Microgravity.xcodeproj -scheme Test -configuration Debug \
  -derivedDataPath "$PWD/DerivedData/Tests" \
  -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" \
  -packageCachePath "$PWD/DerivedData/PackageCache" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -resultBundlePath "$PWD/DerivedData/TestResults/Microgravity-UI.xcresult" \
  -only-testing:MicrogravityUITests test \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=FYJZP8B2KG SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO
```
