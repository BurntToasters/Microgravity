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

The UI XCTest target (`Tests/UITests`) is a hard release gate. `npm run test:all` runs `xcodebuild test` on the complete `Test` scheme, including both `MicrogravityCoreTests` and `MicrogravityUITests`; any UI failure fails the command. `npm run release:prepare` calls `test:all` and records its 24-hour quality proof only after success. Therefore release preparation stays blocked until the signed UI suite passes. Hosted CI runs only Core XCTest and does not satisfy this gate.

The final signed UI run on 2026-11-07 executed 18 tests: 15 passed and 3 failed. The remaining failures are `testDetailsKeepsSelectedProcessAcrossSnapshotRefresh` and `testSelectionSurvivesSnapshotRefresh` (the fixture's one-shot refresh can occur before the test records its baseline), and `testHistorySortsFormattedTotalsByNumericValues` (the saved `history.outline` sort state affects the initial header order). The focused selection/search/sort test passed after accessibility labels and a header hit point were corrected. Group expansion, relaunch persistence, right-click actions, cross-page Details selection, page navigation, sheets, and appearance switching passed in the final full run.

`automationmodetool` takes no arguments. It reported disabled immediately before and after each UI run; one poll during the final run reported enabled. XCUITest did execute real clicks during that transient enabled interval, including successful expansion, relaunch, menu, and page-navigation checks. The remaining failures are test-fixture timing and persisted history sort state; do not attribute them to Automation Mode. Run the full suite on a logged-in GUI host with Automation Mode enabled:

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
