# Microgravity

Microgravity is a native macOS 14+ process and system monitor. Its sidebar provides Processes, Performance, App History, Startup, Users, Details, Services, and Settings. Startup and Services are read-only inventories; process actions target the selected process identity and Force Quit asks for confirmation.

## Build

Install Xcode and Node.js 22.12 or newer, then run `npm ci` and `npm run build:debug`. The unsigned development app is written to `DerivedData/Build/Build/Products/Debug/Microgravity.app`. The non-UI checks and Core XCTest suite run without a GUI session; commands are in [docs/RELEASING.md](docs/RELEASING.md). `npm run test:all` runs both XCTest targets and is a hard release gate through `npm run release:prepare`. UI tests need a signed build, logged-in desktop session, and UI automation authorization. The latest signed composite gate ran 229 tests on a temporary checkout based on `af1359c`: 228 passed (Core 207, UI 21), and the visual minimum-size test failed with three resize assertions. The gate is not green and provides no release proof. Result bundle: `/private/tmp/microgravity-final-audit-6nwsxljc/final-test-all.xcresult`. Signing and distribution are described in [docs/RELEASING.md](docs/RELEASING.md) as well.

## Data and permissions

The app collects local process and system measurements and stores aggregate history locally for up to 30 days. Settings can pause sampling and reset history. Optional helper, login item and update features report their availability in Settings and may require macOS approval. Some metrics and inventory locations can be unavailable or incomplete due to platform support or permissions; the interface identifies those states rather than treating them as zero or an empty inventory.

Microgravity 0.1.0 has not been released. Validation, sync checks, Node tests, and Debug/universal Release smoke builds passed, but the latest 229-test hard gate failed one visual test. Of 48 planned page/appearance/size captures, only 24 default-size images were produced; the window remained at 1280 × 820 during the minimum-size resize. Review also found truncated Settings helper text, and a partial History CPU lower bound still needs a readable presentation. VoiceOver, controlled-process manual sheets, hosted CI, notarization, and update delivery remain unverified. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for exact results and gaps.

## Screenshots

These cropped app-window captures use deterministic UI-test fixture data. They were captured on macOS 27.2 in a restored 1040 × 820 window; they are examples, not a full visual acceptance pass. The later automated visual run produced 24 default-size captures at 2560 × 1640 pixels and no minimum-size captures. A Settings Dark capture showed the helper explanation truncating, so the all-page visual gate remains open.

| Processes | Performance |
| --- | --- |
| ![Processes with expanded fixture group](docs/screenshots/processes-dark.png) | ![Performance with unsupported energy shown](docs/screenshots/performance-dark.png) |

| Settings, Light | Settings, Dark |
| --- | --- |
| ![Settings in Light appearance](docs/screenshots/settings-light.png) | ![Settings in Dark appearance](docs/screenshots/settings-dark.png) |
