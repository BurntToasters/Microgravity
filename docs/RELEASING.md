# Microgravity release procedure

Use a macOS release host with Xcode 26 or newer, Node.js 24.13 or newer, and the `gh` and `gpg` command-line tools. The Xcode project builds the app for macOS 14 and newer. Development and CI builds are unsigned and need no signing credentials.

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

Hosted CI (`.github/workflows/ci.yml`) runs the Node suite, project and version checks, validation, unsigned Core XCTest, and both builds. It does not run UI XCTest. GitHub lists `macos-26` as a hosted runner and announced general availability on 2026-02-26 ([runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job), [announcement](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/)). This confirms runner-label availability; it does not mean CI was run against this working tree. Hosted CI has not run for this tree: it is blocked because the repository owner's GitHub Actions minutes are exhausted for this month. This is not a failure. See `docs/IMPLEMENTATION_STATUS.md`.

`build:release-smoke` only proves an unsigned universal Release compile. It does not sign or notarize an artifact.

## UI tests and the release gate

`npm run test:all` runs `xcodebuild test` on the complete `Test` scheme, including both `MicrogravityCoreTests` and `MicrogravityUITests`; any test failure fails the command. `npm run test:all -- --skip-ui` runs every gate except the UI automation suite (`-skip-testing:MicrogravityUITests`).

`npm run release:prepare` runs `test:all -- --skip-ui` by default: version, project, and workspace checks, the Node suite, and Core XCTest. It records its 24-hour quality proof only after success, and the proof's `gate` field names the command that ran. Set `MICROGRAVITY_RELEASE_UI_TESTS=1` to include the UI suite in a release run. The UI suite is slow and takes over the desktop, so run the full `npm run test:all` (signed, on a logged-in session) whenever a change touches the interface, and before a release that contains interface changes since the last full run. An older `--skip-ui` run recorded on 2026-11-08 executed 220 Core tests, 0 failed, 0 skipped, from the `~/Documents` checkout without hanging. That count is superseded by the 2026-11-08 results below.

Latest results, 2026-11-08, branch `next-0.1.2` (commit `f8b6a68` plus test fixes that were later committed):

- Unsigned Core XCTest executed 286 tests, 0 failed.
- Signed UI tests (`-only-testing:MicrogravityUITests`, the command below, `DEVELOPMENT_TEAM=FYJZP8B2KG`, run from the `~/Documents` checkout) executed 23 tests: 21 passed and 2 failed. Both failures were stale assertions after 0.1.1: `testHistoryShowsGapsAndRequiresConfirmationToReset` checked the gap row without waiting after expanding an app that was now collapsed, and `testDetailsIsFlatAndShowsUnavailableMetricsExplicitly` expected "Unsupported" where the banner now says the network column needs the optional helper. Both tests were fixed and passed on rerun. The full UI suite was not rerun after the fixes.
- These were not `npm run test:all` composite runs, so no release proof was recorded.

The results below from 2026-11-07 are the last complete signed run. The signed run on 2026-11-07, on source `ec836a6` plus uncommitted `gate/0.1.0` changes from an isolated worktree outside `~/Documents`, exited 0: 243 tests executed (Core 220, UI 23), 0 failed, 0 skipped, 0 expected failures. It used `MICROGRAVITY_UI_SIGNING_IDENTITY='Apple Development' MICROGRAVITY_UI_TEAM_ID=<team-id> npm run test:all`. `test:all` reported `dirty worktree; no reusable release proof recorded`. Hosted CI runs only Core XCTest and records no release proof.

In the 2026-11-07 run, the UI suite executed 23 tests with 0 failures and 0 skipped. The visual matrix captured 8 pages in System, Light, and Dark appearances at 1280 × 820 and 960 × 600 (48 captures), and the App History gap test adds 2 captures. The manager reviewed all of them; known visual issues are listed in `docs/IMPLEMENTATION_STATUS.md`. Fixture monitoring emits repeatable later snapshots; refresh tests establish selection, record current freshness, then wait for another refresh and assert selection remains attached. Expansion persistence is checked through native disclosure state across relaunch; history sorting uses native header clicks in both directions. The Debug fixture app clears per-test defaults on graceful termination only when XCTest markers, `--ui-test-fixtures`, and an exact `Microgravity.UITests.test…` suite name match. UI-test teardown sends Command-Q and waits for process exit; the persistence test force-terminates mid-test so expansion survives until final teardown. The app clears only that suite and autosave keys derived from it, synchronizes and verifies removal, and cancels termination on cleanup failure. The external host audit found zero nonempty fixture domains and zero matching autosave keys.

Automation Mode was not sampled during the 2026-11-07 suite. The signed runs on 2026-11-07 and 2026-11-08 each logged 23 occurrences of "This method should not be called on the main thread as it may lead to UI unresponsiveness." (one per UI test that launches the app; 0 from Core tests). The warning is emitted in the app process at the runner's first accessibility snapshot and is attributed to macOS LaunchServices and Security checks, with no Microgravity source frame. It is unresolved and not suppressed. No zero-diagnostics claim is made. Run the suite on a logged-in GUI host with UI automation authorized:

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

Substitute the 10-character Apple Team ID for `<team-id>`. The UI tests use fixture data and need no helper approval or Sparkle feed. Do not disable or skip failing UI tests to make the full `test:all` pass; fix them.

Troubleshooting:

- `Failed to initialize for UI testing ... Canceled by user`: Automation Mode is off, or the runner tried to use biometrics. Check with `automationmodetool` (no arguments).
- The runner is killed before connecting, or hangs before connecting: the runner is unsigned. Use the signed command and the correct team ID.
- `dyld` reports different Team IDs when loading Sparkle: the Debug configuration must keep `ENABLE_HARDENED_RUNTIME = NO` (`config/debug.xcconfig`). Delete `DerivedData/Build` and rebuild.
- `Missing package product 'Sparkle'`: delete `DerivedData/Build`, `DerivedData/SourcePackages`, and `DerivedData/PackageCache`, then rebuild. `scripts/build.mjs` converts package and tool paths to absolute paths because Xcode silently resolves no local packages from relative paths; do not revert that.
- UI element not found or timeout: inspect failure attachments and the accessibility hierarchy with `xcrun xcresulttool`. Check the actual native control type and accessibility identifiers before changing a test.
- `test runner hung before establishing connection` from a checkout under `~/Documents`: the unsigned test host triggers a macOS privacy (Documents folder) prompt while loading Sparkle.framework from DerivedData. Run the gates from a checkout outside `~/Documents`.

## Updating Sparkle

`sparkle_pin.yml` names the Sparkle release Microgravity vendors: its version, build, tag commit, and the SHA-256 of the official `Sparkle-<version>.tar.xz`. To move to another release, take those values from <https://github.com/sparkle-project/Sparkle/releases> (the file's comments list the commands), then run `./get_sparkle.sh`. It refuses to install unless the download matches the pinned checksum and GitHub's published digest, the tag resolves to the pinned commit, and the release reports the pinned version and build. It updates only pristine library sources and upstream translations, keeps Microgravity's own translations (`en.lproj`) and local edits that upstream did not touch, and stops on any other conflict. Vendored helpers stay ad hoc signed; the release build signs them with the app. Add a `CHANGELOG.md` entry, run `npm run validate` and `npm run test:all`, and commit. `./get_sparkle.sh --verify-only` checks `vendor/Sparkle` against the official release without writing anything; `npm run validate` checks `vendor/Sparkle/UPSTREAM` and the versions against the pin offline. Do not hand-edit `vendor/Sparkle` sources, helpers, or `sign_update`.

The vendored copy omits `generate_keys` and `generate_appcast`. `./get_sparkle.sh --tools [DIR]` runs the same verification, then installs the complete pinned release into `DIR` (default `~/Sparkle`) without touching `vendor/Sparkle`. An existing `DIR` is moved aside to `DIR.previous-<version>-<timestamp>`, never deleted; Sparkle keys live in the login keychain, so replacing the directory does not affect them.

## Manual UI checklist (0.1.0)

Run this on a Mac with a logged-in desktop session before tagging, and record the date, macOS version, Xcode version, and any failure in `docs/IMPLEMENTATION_STATUS.md`.

1. Every page (Processes, Performance, App History, Startup, Users, Details, Services, Settings) in System, Light, and Dark appearance, at the default size of 1280 × 820 and at the minimum size of 960 × 600. Check for clipped or overlapping text, unreadable badges and heat-map colors, status indicators that rely on color alone, and any horizontal scrolling of the page body. Also resize the window by hand to 960 × 600 and back. The automated matrix in `docs/UI_ACCEPTANCE.md` captures these states but does not replace this check.
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
