# Microgravity release procedure

Use a macOS release host with Xcode 26 or newer, Node.js 22.12 or newer, and the `gh` and `gpg` command-line tools. The Xcode project builds the app for macOS 14 and newer. Development and CI builds are unsigned and need no signing credentials.

## Configure the release host

Copy `.env.example` to the ignored `.env` file, then configure credentials obtained specifically for Microgravity:

- A Sparkle EdDSA key pair. Put only the public key in `MICROGRAVITY_SPARKLE_PUBLIC_KEY`; choose exactly one private-key source for signing. Without the public key, automatic update checks stay disabled. Release preflight blocks until both public and signing keys are configured.
- A Developer ID Application identity in the keychain, its Apple Team ID, and a `notarytool` keychain profile name.
- A GPG signing key (a fingerprint or unambiguous key selector). Signatures must verify against this key or its subkey. `MICROGRAVITY_GPG_PASSPHRASE` is optional when `gpg-agent` handles prompts.
- GitHub CLI authentication. On an interactive release host, run `gh auth login`; `gh` keeps the credential in the login keychain and no token variable is needed. For token-authenticated automation, set `GH_TOKEN` or `GITHUB_TOKEN` in the process environment instead. Microgravity passes those variables only to `gh` child processes; build, test, signing, and notarization subprocesses have them stripped. Do not put a token in `.env` or source control.

Keep private keys and passphrases out of source control. The Node build and Xcode subprocesses do not inherit the configured Sparkle or GPG private key values; signing tools receive direct key material over standard input when that mode is used.

## Run local and CI gates

Run the non-UI gates on any macOS host with Xcode 26 or newer:

```sh
npm ci --ignore-scripts
npm run project:sync -- --check
npm run sync-version -- --check
npm run validate
npm run test:node
npm run build:debug
npm run build:release-smoke
```

Run the Core XCTest suite. It is unsigned and needs no GUI session:

```sh
mkdir -p DerivedData/TestResults
rm -rf DerivedData/TestResults/Microgravity-Core.xcresult
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

Use `-destination 'platform=macOS,arch=x86_64'` on an Intel host. The suite must finish with 0 failures.

Hosted CI (`.github/workflows/ci.yml`) runs the Node suite, project and version checks, validation, unsigned Core XCTest, and both builds. It does not run UI XCTest. GitHub lists `macos-26` as a hosted runner and announced general availability on 2026-02-26 ([runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job), [announcement](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)). This confirms runner-label availability; it does not mean CI was run against this working tree. See `docs/IMPLEMENTATION_STATUS.md`.

`build:release-smoke` only proves an unsigned universal Release compile. It does not sign or notarize an artifact.

## UI tests and the hard release gate

The UI XCTest target (`Tests/UITests`) is a hard release gate. `npm run test:all` runs `xcodebuild test` on the complete `Test` scheme, including both `MicrogravityCoreTests` and `MicrogravityUITests`; any test failure fails the command. `npm run release:prepare` calls `test:all` and records its 24-hour quality proof only after success. An earlier gate passed 224 tests on the preceding app-cleanup patch; that result is superseded for current source. The latest manager run on a temporary verification checkout based on `af1359c` executed 229 tests (Core 207 + UI 22): 228 passed, 1 failed, 0 skipped. The visual minimum-size test left the window at 1280 × 820 instead of 960 × 600, causing three failed assertions. Result bundle: `/private/tmp/microgravity-final-audit-6nwsxljc/final-test-all.xcresult`. The gate is red and creates no reusable release proof. An external host Preferences audit of the accepted cleanup patch found zero nonempty `Microgravity.UITests.*` domains and zero fixture autosave keys. Hosted CI runs only Core XCTest and does not satisfy this gate.

The latest signed UI suite executed 22 tests: 21 passed, 1 failed, 0 skipped. The failed test's three assertions are in the visual minimum-size interaction; no minimum-size captures were produced. It did capture 24 default-size PNGs (2,560 × 1,640 pixels) across eight pages and three appearances. Manager inspection found the Settings Dark helper explanation truncated, and History's partial CPU lower bound remains a readability issue. Fixture monitoring emits repeatable later snapshots; refresh tests establish selection, record current freshness, then wait for another refresh and assert selection remains attached. Expansion persistence is checked through native disclosure state across relaunch; history sorting uses native header clicks in both directions. The Debug fixture app clears per-test defaults on graceful termination only when XCTest markers, `--ui-test-fixtures`, and an exact `Microgravity.UITests.test…` suite name match. UI-test teardown sends Command-Q and waits for process exit; the persistence test force-terminates mid-test so expansion survives until final teardown. The app clears only that suite and autosave keys derived from it, synchronizes and verifies removal, and cancels termination on cleanup failure. The external host audit found zero nonempty fixture domains and zero matching autosave keys.

Automation Mode was not sampled during the latest suite. The final composite audit recorded 22 runtime warnings. Helper validation now runs in the background and the focused Core trace warning is resolved; a separate UI Security callback warning remains. No zero-diagnostics claim is made. Run the suite on a logged-in GUI host with UI automation authorized:

- The runner must be a logged-in desktop session. UI tests cannot run over SSH or on a locked screen.
- Automation Mode must be enabled. Check its current state by running `automationmodetool` with no arguments. Enabling it requires an administrator and lowers UI-automation security, so enable it only on a dedicated runner.
- The UI runner needs a real Apple Development signature. Ad-hoc or unsigned runners fail before connecting. Find the identity with `security find-identity -v -p codesigning`.

```sh
mkdir -p DerivedData/TestResults
rm -rf DerivedData/TestResults/Microgravity-UI.xcresult
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
  DEVELOPMENT_TEAM="<team-id>" \
  SPARKLE_ENABLE_AUTOMATIC_CHECKS=NO
```

Substitute the 10-character Apple Team ID for `<team-id>`. The UI tests use fixture data and need no helper approval or Sparkle feed. Do not disable the UI target or change the release gate to make `test:all` pass.

Troubleshooting:

- `Failed to initialize for UI testing ... Canceled by user`: Automation Mode is off, or the runner tried to use biometrics. Check with `automationmodetool` (no arguments).
- The runner is killed before connecting, or hangs before connecting: the runner is unsigned. Use the signed command and the correct team ID.
- `dyld` reports different Team IDs when loading Sparkle: the Debug configuration must keep `ENABLE_HARDENED_RUNTIME = NO` (`config/debug.xcconfig`). Delete `DerivedData/Build` and rebuild.
- `Missing package product 'Sparkle'`: delete `DerivedData/Build`, `DerivedData/SourcePackages`, and `DerivedData/PackageCache`, then rebuild. `scripts/build.mjs` converts package and tool paths to absolute paths because Xcode silently resolves no local packages from relative paths; do not revert that.
- UI element not found or timeout: inspect failure attachments and the accessibility hierarchy with `xcrun xcresulttool`. Check the actual native control type and accessibility identifiers before changing a test.

## Manual UI checklist (0.1.0)

Run this on a Mac with a logged-in desktop session before tagging, and record the date, macOS version, Xcode version, and any failure in `docs/IMPLEMENTATION_STATUS.md`.

1. Every page (Processes, Performance, App History, Startup, Users, Details, Services, Settings) in System, Light, and Dark appearance, at the default size of 1280 × 820 and at the minimum size of 960 × 600. Check for clipped or overlapping text, unreadable badges and heat-map colors, status indicators that rely on color alone, and any horizontal scrolling of the page body.
2. VoiceOver spot check: the sidebar (group names, page names, and selection are announced) and the Processes outline (row name and PID are announced; expand and collapse are announced; selection follows the row).
3. Force Quit sheet: start a throwaway process you own (for example `sleep 600` from Terminal), select it in Processes, and choose Force Quit. The confirmation must appear as a sheet attached to the main window. Cancel must leave the process running. Confirming must end it. Do not use a process you do not own.
4. Reset History sheet: open App History and choose Reset History. The confirmation must appear as a sheet. Cancel must leave history unchanged. Confirming must clear App History and must not change any process data.
5. Closing the last window quits the app.

## Prepare and publish

The package version in `package.json` is authoritative. Increment `buildNumber` for every Sparkle update, add release notes under the matching version in `CHANGELOG.md`, then run `npm run sync-version` and commit those metadata changes before release.

Run `npm run release:mac` on the canonical `main` branch for a stable release or `beta` branch for a beta. The command checks the GitHub origin, clean worktree, upstream and remote commit, release metadata, credentials, and quality gates. It records a 24-hour quality proof/session tied to the source, dependency, project, and toolchain identities; then builds a universal app, signs it, submits and staples notarization, packages the appcast, verifies the archive against the configured Sparkle public key, signs release files with GPG, and uploads a draft. Before publication it checks the downloaded draft files against a session-bound manifest, then verifies the published downloads and live feed.

Stable releases include the canonical `appcast.xml` and a signed `appcast-beta.xml` fallback pointing to that stable build. A later beta publication replaces the beta feed and its GPG signature on the current stable release, so that mirror is mutable. `SHA256SUMS` covers only the archive and canonical channel feed; the initial session-bound artifact manifest also binds the stable fallback and its GPG signature.

Drafts must target the verified commit SHA. A draft that targets a branch name (`main` or `beta`) is rejected; delete it with `gh release delete <tag> --repo BurntToasters/Microgravity --yes` and re-run the release so it is created against the commit.

## Recovering a partially published release

A beta publish uploads the replacement `appcast-beta.xml` and `.asc` to the current stable release before the beta leaves draft. If that upload fails, the beta is still a draft and can be resumed with `npm run release:mac:resume` (or `release:mac:continue` then `release:publish`) while the 24-hour session is valid. If the session has expired, run `npm run release:prepare` again.

If the beta is already published, `continue` logs that and skips rebuilding and uploading, so `release:mac:resume` proceeds to `publish`. `publish` re-verifies the published assets, re-uploads the stable mirror (it is mutable), and skips the draft-state edit. The mirror can therefore point at a beta that is still a draft between the mirror upload and the draft=false edit; finish the publish promptly if it fails at that step.

For an already prepared release, `npm run release:mac:resume` verifies the same session and resumes the release. `npm run release:session:verify` prints whether the session still matches. If code, version metadata, toolchain, or session age changes, prepare again. Releases remain blocked until the actual Microgravity keys and Apple/GPG credentials are provisioned.
