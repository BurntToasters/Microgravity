# TASK.md — finish Microgravity verification on the VM

Handoff for the agent running in a disposable macOS VM with administrator
access. The repository is already implemented. The remaining work is to enable
Automation Mode, run the signed UI tests, fix any UI-test failures, and record
the final evidence.

Work directly in the existing checkout. **Do not commit, push, reset, stash,
clean, or rewrite history.** All work stays uncommitted.

## 0. Baseline verified on the authoring host

On 2026-11-04 (macOS 27.2, Xcode 27.2, arm64, Node 26.13.0):

- `npm run validate` — pass
- `npm run test:node` — 19/19 pass
- `npm run build:debug` — pass
- `npm run build:release-smoke` — pass
- Core XCTest via `-only-testing:MicrogravityCoreTests` — 44/44 pass
- Signed `test:all` — Core 44/44 pass; the signed UI runner builds and launches,
  then stops at `Failed to initialize for UI testing: com.apple.LocalAuthentication
  Code=-2 "Canceled by user." BiometryType=1`. Automation Mode is disabled and
  the host cannot complete biometric authentication in closed-clamshell mode.

Two fixes were required to reach that baseline and are already in the tree:

- `config/debug.xcconfig` sets `ENABLE_HARDENED_RUNTIME = NO` so the ad-hoc
  Debug app can load the embedded Sparkle framework without a Team ID match.
  Release keeps the hardened runtime.
- `scripts/build.mjs` converts Xcode tool paths to absolute paths. Xcode 27.2
  silently resolves zero local packages when `-packageCachePath` is relative,
  which produces `Missing package product 'Sparkle'`.

## 1. Preconditions

Run these first and paste the output into `TEST_RESULTS.md`:

```sh
cd /path/to/Microgravity
sw_vers
xcodebuild -version
node --version
uname -m
git status --short
security find-identity -v -p codesigning
```

Requirements:

- macOS 14 or newer with Xcode 27.2 installed (`xcode-select -p` must point at
  that Xcode).
- Node.js 22.12 or newer.
- A logged-in GUI desktop session. UI tests launch and drive a real app; they
  cannot pass from an SSH-only or locked session. Keep the VM console/Screen
  Sharing session connected while tests run.
- If `node_modules` is absent, run `npm ci --ignore-scripts`, then
  `npm run sync-version && npm run project:sync`.
- The Sparkle package is vendored at `vendor/Sparkle`; network access is not
  required for the build.

## 2. Enable Automation Mode (required sudo step)

The host requires administrator authentication. Run exactly:

```sh
sudo automationmodetool enable-automationmode-without-authentication
automationmodetool
```

Expected final output:

```text
Automation Mode is enabled.
```

Use the `without-authentication` variant. This VM has no usable Touch ID, so
the interactive `enable-automationmode` command cannot complete. Enabling this
mode lowers UI-automation security; that is acceptable only in this disposable
VM. Do not disable SIP, Gatekeeper, or TCC, and do not edit security databases.
If `sudo` prompts, the operator must type the password; never store it.

If the command is not on `PATH`:

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/automationmodetool
```

## 3. Confirm the signing identity

UI tests need a real Apple Development signature. Ad-hoc or unsigned runners
fail before establishing a connection.

```sh
security find-identity -v -p codesigning
```

Use the available Apple Development identity, for example:

```text
Apple Development: Johann Smith (W22N3XDGQU)
```

The team for that certificate is `FYJZP8B2KG` (the parenthesized value is not
the team ID). If the VM has a different identity/team, substitute both values
in the commands below.

## 4. Run the non-UI gates

```sh
npm run validate
npm run test:node
npm run build:debug
npm run build:release-smoke
```

Expected:

- `validate: ok`
- 19/19 Node tests pass
- `build:debug: ok (unsigned development app)`
- `build:release-smoke: ok (unsigned universal Release compile)`

The Debug app is at:

```text
DerivedData/Build/Build/Products/Debug/Microgravity.app
```

Run the 44 Core tests:

```sh
rm -rf DerivedData/TestResults/Microgravity-Core.xcresult
mkdir -p DerivedData/TestResults
xcodebuild \
  -project Microgravity.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -derivedDataPath "$PWD/DerivedData/Tests" \
  -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" \
  -packageCachePath "$PWD/DerivedData/PackageCache" \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$PWD/DerivedData/TestResults/Microgravity-Core.xcresult" \
  -only-testing:MicrogravityCoreTests \
  test \
  CODE_SIGNING_ALLOWED=NO \
  SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO
```

Use `arch=x86_64` only if the VM is Intel. Expected: 44 tests, 0 failures.

## 5. Run the signed UI tests

`npm run test:all` signs the UI tests only when both signing environment
variables are set; without them it builds the UI runner unsigned. Use the
explicit signed command below, or run `test:all` with the variables shown after
the command.

```sh
rm -rf DerivedData/TestResults/Microgravity-UI.xcresult
mkdir -p DerivedData/TestResults
xcodebuild \
  -project Microgravity.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -derivedDataPath "$PWD/DerivedData/Tests" \
  -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" \
  -packageCachePath "$PWD/DerivedData/PackageCache" \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$PWD/DerivedData/TestResults/Microgravity-UI.xcresult" \
  -only-testing:MicrogravityUITests \
  test \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=FYJZP8B2KG \
  SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO
```

Expected: all 13 UI tests pass. They use fixture data; no real helper approval
or Sparkle feed is needed.

After the UI suite passes, run the whole gate with signing enabled:

```sh
MICROGRAVITY_UI_SIGNING_IDENTITY="Apple Development" \
MICROGRAVITY_UI_TEAM_ID=FYJZP8B2KG \
npm run test:all
```

Without those variables, `test:all` builds the UI test bundle unsigned and the
runner may fail before establishing a connection. `test:all` writes its result
bundle to `DerivedData/TestResults/Microgravity.xcresult`.

Because `docs/IMPLEMENTATION_STATUS.md` and this file are uncommitted,
`test:all` will not record release proof. That is expected; do not commit just to
make it clean.

## 6. Known open UI failure

`testProcessesExpandSearchSortAndKeepSelectionIdentity` has never passed on the
previous host. It covers the process table in
`Sources/UI/ProcessesViewController.swift`:

- expand the `fixture-editor` group and select PID 410;
- verify the selected identity contains `pid=410`;
- search for `Renderer`; PID 410 must remain visible and PID 620 must be hidden;
- click the CPU column header; the selected identity must not change.

Diagnose with the `.xcresult` bundle. Fix the product behavior unless the test
contradicts `docs/UI_ACCEPTANCE.md`; do not weaken or delete the assertion just
to get a pass. Keep the change minimal and rerun the signed UI command until all
13 tests pass.

## 7. Troubleshooting

| Symptom | Action |
| --- | --- |
| `Automation Mode is disabled` | Rerun step 2 and confirm with `automationmodetool`. |
| `Failed to initialize for UI testing ... Canceled by user ... BiometryType=1` | Automation Mode is still off, or the VM tried to use biometrics. Use the `without-authentication` command. |
| dyld `different Team IDs` when launching Sparkle | Debug must have `ENABLE_HARDENED_RUNTIME = NO` (`config/debug.xcconfig`). Delete `DerivedData/Build` and rebuild. |
| `Missing package product 'Sparkle'` | Package cache paths must be absolute. The scripts now convert them; delete `DerivedData/Build`, `DerivedData/SourcePackages`, and `DerivedData/PackageCache`, then rerun. Do not revert `absoluteToolPaths` in `scripts/build.mjs`. |
| `signal kill before establishing connection` or hung before connecting | The UI runner is unsigned. Use the signed command in step 5 and verify the identity/team. |
| UI element not found / timeout | Inspect `DerivedData/TestResults/Microgravity-UI.xcresult` with `xcrun xcresulttool` and read the attached screenshot. Check accessibility identifiers before changing the test. |

## 8. Update the status documentation

After the gates finish, update `docs/IMPLEMENTATION_STATUS.md` with:

- date, macOS version, Xcode version, architecture;
- exact pass/fail counts for Node, Core, and UI tests;
- build results for Debug and release-smoke;
- the Automation Mode prerequisite and that it was enabled in the VM;
- what remains unverified: Developer ID signing, notarization, Sparkle update
  delivery, helper authorization against the live daemon, VoiceOver, and
  long-running real-world performance.

Do not claim signed distribution or notarization was verified. No release
credentials are configured, and release commands are out of scope. Do not run
`npm run release:*`, `codesign` with distribution identities, or notarization.

Also write `TEST_RESULTS.md` at the repository root with the commands used and
their tail output.

## 9. Handoff back

Leave every change uncommitted and report:

```sh
git status --porcelain=v1
```

For each changed file, return the full contents or a patch. Use `git diff` for
tracked changes and `git status --porcelain` for untracked files; `TASK.md` is
untracked in the authoring checkout. Include:

- the exact commands run and their exit codes;
- Node/Core/UI test counts;
- the `.xcresult` paths;
- any product fix made for the process table;
- the updated `TEST_RESULTS.md` and `docs/IMPLEMENTATION_STATUS.md`.

If the VM will be kept after verification, undo the setting:

```sh
sudo automationmodetool disable-automationmode-without-authentication
```

Success means: `validate` passes, 19 Node tests pass, 44 Core tests pass, 13 UI
tests pass, both builds succeed, and no security or signing shortcut was used.
