# Contributing to Microgravity

Thanks for helping improve Microgravity. This guide covers the local workflow; release automation is documented separately in [docs/RELEASING.md](docs/RELEASING.md).

## Before you start

- Search [existing issues](https://github.com/BurntToasters/Microgravity/issues) before opening a new one.
- Open an issue to discuss large features, refactors, or behavior changes before writing the code.
- Do not report security vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md).
- By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

Requirements:

- macOS 14 or later
- Xcode 26 or later
- Node.js 24.13 or later

Build the unsigned development app:

```sh
npm ci
npm run build:debug
```

The app is written to `DerivedData/Build/Build/Products/Debug/Microgravity.app`.

Run the non-UI checks:

```sh
npm run project:sync -- --check
npm run sync-version -- --check
npm run validate
npm run test:node
npm run test:all -- --skip-ui
```

`npm run test:all` runs both the Core and UI XCTest suites. The UI suite needs a signed build, a logged-in desktop session, and UI automation permission; run it when your change touches the interface. Do not disable or skip a failing UI test to make the full suite pass.

CI runs the Node suite, project and version checks, validation, unsigned Core XCTest, and the debug and release-smoke builds. It does not run the UI suite. See [docs/RELEASING.md](docs/RELEASING.md) for the complete gate and release procedure.

## Coding style

Match the conventions already used in the file and surrounding modules:

- Keep the app native AppKit and Swift, with UI work on the main actor.
- Localize user-facing strings with `String(localized:)`.
- Give interactive controls stable accessibility identifiers and labels when they are covered by tests or assistive technology.
- Keep unavailable measurements explicit. Never show a missing value as zero or an empty list as complete.
- Add or update tests in `Tests/CoreTests` or `Tests/UITests` for behavior changes.
- Keep fixes focused. Separate broad refactors and formatting-only changes from behavior changes.

There is no repository-wide formatter configuration, so follow the existing formatting rather than introducing a new style. Discuss new third-party dependencies before adding them; Sparkle is already vendored and tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Pull requests

1. Fork the repository and create a topic branch from `main` (or `beta` for an in-progress release line).
2. Make one focused change and include tests for behavior changes.
3. Run the relevant checks above and record the commands and results in the pull request.
4. Update documentation and `CHANGELOG.md` for user-visible changes.
5. Open the pull request and fill out the template. Link the issue it resolves, and include screenshots or a recording for UI changes.

Keep the pull request description factual. If a check could not run, say why instead of marking it as passed. Review conversations should stay on the code and the user impact.

## License and contribution terms

Microgravity is distributed under `GPL-3.0-only`. Unless you explicitly agree otherwise, contributions are accepted under the same license, and you retain copyright in your work. By submitting a contribution, you confirm that:

- You wrote the contribution, or you have the right to submit it under GPL-3.0-only.
- Any third-party code, assets, or data are compatible with that license and are attributed in the pull request and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) where applicable.
- You have not included confidential information, credentials, or code you do not have permission to publish.

No copyright assignment is required.
