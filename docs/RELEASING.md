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

Hosted CI (`.github/workflows/ci.yml`) runs the Node suite, project and version checks, validation, unsigned Core XCTest, and both builds. It does not run UI XCTest. The runner label in that workflow has not been verified for this release; see `docs/IMPLEMENTATION_STATUS.md`.

`build:release-smoke` only proves an unsigned universal Release compile. It does not sign or notarize an artifact.

## UI tests and the release gate

The UI XCTest target (`Tests/UITests`) has not passed on any host for this release. The recorded failures are interaction failures: synthesized clicks and keystrokes did not produce the expected page changes or row expansion in the test VM, and the cause has not been isolated. For 0.1.0 the UI suite is therefore not a release gate that can be met. The 0.1.0 UI verification is the Core XCTest suite, which includes AppKit view-controller tests, plus the manual checklist below. The signed UI suite stays in the repository as a goal for a later release, to be made a gate once it runs green on a dedicated logged-in GUI runner.

Current script behavior differs from that decision, and the difference is not resolved in this document:

- `npm run test:all` (`scripts/test-all.mjs`) runs `xcodebuild test` on the whole `Test` scheme, which contains both `MicrogravityCoreTests` and `MicrogravityUITests`. It does not filter to Core. A failing UI test therefore fails `test:all`.
- `npm run release:prepare` runs `npm run test:all` (`scripts/release.mjs`) and records the 24-hour quality proof only when it passes. `release:mac` calls `release:prepare`. A release cannot be prepared while the UI suite fails.
- Hosted CI runs only the unsigned Core command above, so CI is not affected.

Before tagging 0.1.0, one of these must be true: the UI suite runs green on a signed GUI runner, or the owner changes `scripts/test-all.mjs` (and the release path that depends on it) so the UI target is not part of the release gate. Do not describe the release as gated on UI tests until that change is made.

To run the signed UI suite on a GUI runner (for development or for a later release gate):

- The runner must be a logged-in desktop session. UI tests cannot run over SSH or on a locked screen.
- Automation Mode must be enabled. Check it with `automationmodetool`. Enabling it requires an administrator and lowers UI-automation security, so do it only on a dedicated runner.
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

Substitute the 10-character Apple Team ID for `<team-id>`. The UI tests use fixture data and need no helper approval or Sparkle feed.

Troubleshooting:

- `Failed to initialize for UI testing ... Canceled by user`: Automation Mode is off, or the runner tried to use biometrics. Check `automationmodetool`.
- The runner is killed before connecting, or hangs before connecting: the runner is unsigned. Use the signed command and the correct team ID.
- `dyld` reports different Team IDs when loading Sparkle: the Debug configuration must keep `ENABLE_HARDENED_RUNTIME = NO` (`config/debug.xcconfig`). Delete `DerivedData/Build` and rebuild.
- `Missing package product 'Sparkle'`: delete `DerivedData/Build`, `DerivedData/SourcePackages`, and `DerivedData/PackageCache`, then rebuild. `scripts/build.mjs` converts package and tool paths to absolute paths because Xcode silently resolves no local packages from relative paths; do not revert that.
- UI element not found or timeout: open the `.xcresult` bundle with `xcrun xcresulttool` and read the attached screenshots. Check the accessibility identifiers before changing a test.

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
