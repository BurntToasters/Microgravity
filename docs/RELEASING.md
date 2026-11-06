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
npm run project:sync
npm run sync-version
npm run validate
npm run test:node
npm run build:debug
npm run build:release-smoke
```

Core XCTest is also unsigned and needs no GUI. Use the `-only-testing:MicrogravityCoreTests` command in `TASK.md` section 4, which sets `CODE_SIGNING_ALLOWED=NO` and writes `DerivedData/TestResults/Microgravity-Core.xcresult`. Hosted CI (`.github/workflows/ci.yml`) runs these same non-UI gates.

## Signed UI gate

Hosted macOS runners do not provide a logged-in GUI session or Automation Mode, so hosted CI cannot run UI XCTest. The signed UI XCTest gate must run on a dedicated logged-in GUI runner, normally self-hosted macOS, with an Apple Development signing identity and Automation Mode enabled. It is mandatory before every release and is not skipped for releases. Use the signed `-only-testing:MicrogravityUITests` command in `TASK.md` section 5, then run the full signed suite on that runner:

```sh
MICROGRAVITY_UI_SIGNING_IDENTITY="Apple Development" \
MICROGRAVITY_UI_TEAM_ID="<team-id>" \
npm run test:all
```

`test:all` runs the Node suite plus both Core XCTest and UI XCTest targets and saves the `.xcresult` bundle under ignored `DerivedData/TestResults/`. The UI tests run as a real gate; an unavailable UI runner is a failure, not a skip. `build:release-smoke` only proves an unsigned universal Release compile. It does not notarize or sign an artifact.

## Prepare and publish

The package version in `package.json` is authoritative. Increment `buildNumber` for every Sparkle update, add release notes under the matching version in `CHANGELOG.md`, then run `npm run sync-version` and commit those metadata changes before release.

Run `npm run release:mac` on the canonical `main` branch for a stable release or `beta` branch for a beta. The command checks the GitHub origin, clean worktree, upstream and remote commit, release metadata, credentials, and quality gates. It records a 24-hour quality proof/session tied to the source, dependency, project, and toolchain identities; then builds a universal app, signs it, submits and staples notarization, packages the appcast, verifies the archive against the configured Sparkle public key, signs release files with GPG, and uploads a draft. Before publication it checks the downloaded draft files against a session-bound manifest, then verifies the published downloads and live feed.

For an already prepared release, `npm run release:mac:resume` verifies the same session and resumes the release. `npm run release:session:verify` prints whether the session still matches. If code, version metadata, toolchain, or session age changes, prepare again. Releases remain blocked until the actual Microgravity keys and Apple/GPG credentials are provisioned.
