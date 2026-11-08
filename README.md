# Microgravity

Microgravity is a native macOS 14+ process and system monitor. Its sidebar provides Processes, Performance, App History, Startup, Users, Details, Services, and Settings. Startup and Services are read-only inventories; process actions target the selected process identity and Force Quit asks for confirmation.

## Build

Install Xcode and Node.js 22.12 or newer, then run `npm ci` and `npm run build:debug`. The unsigned development app is written to `DerivedData/Build/Build/Products/Debug/Microgravity.app`. The non-UI checks and Core XCTest suite run without a GUI session; commands are in [docs/RELEASING.md](docs/RELEASING.md). `npm run test:all` runs both XCTest targets and is a hard release gate through `npm run release:prepare`. UI tests need a signed build, logged-in desktop session, and UI automation authorization. The latest signed `npm run test:all` run exited 0 with 243 tests executed (Core 220, UI 23), 0 failed, and 0 skipped, on commit `ec836a6` plus the uncommitted `gate/0.1.0` changes. The run reported a dirty worktree, so it provides no reusable release proof. The local result bundle is `DerivedData/Evidence/gate-2026-11-07/final-test-all.xcresult` (gitignored, not committed). Signing and distribution are described in [docs/RELEASING.md](docs/RELEASING.md) as well.

## Data and permissions

The app collects local process and system measurements and stores aggregate history locally for up to 30 days. Settings can pause sampling and reset history. Optional helper, login item and update features report their availability in Settings and may require macOS approval. Some metrics and inventory locations can be unavailable or incomplete due to platform support or permissions; the interface identifies those states rather than treating them as zero or an empty inventory.

Microgravity 0.1.0 has not been released. Validation, sync checks, Node tests (32 passed), and Debug and universal Release smoke builds passed. The signed composite gate passed (243 tests, 0 failed, 0 skipped), but it ran from a dirty worktree and creates no release proof. The visual matrix captured 8 pages in System, Light, and Dark appearances at 1280 × 820 and 960 × 600 (48 captures), plus 2 App History gap captures; all were reviewed by the manager. Manual drag-resize, VoiceOver, live process actions, hosted CI (not run: GitHub Actions minutes are exhausted), notarization, and update delivery remain unverified. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for exact results and gaps.

## Screenshots

Processes and Performance are cropped app-window captures with deterministic UI-test fixture data. They were captured on macOS 27.2 in a restored 1040 × 820 window during an earlier signed test run. The Settings images are full default-size window captures (1280 × 820 points, 2560 × 1640 pixels) from the final visual matrix run on 2026-11-07 (macOS 27.2, Xcode 27.2), downscaled to 2080 pixels wide. All four show fixture states and are examples, not a complete visual acceptance pass.

| Processes | Performance |
| --- | --- |
| ![Processes with expanded fixture group](docs/screenshots/processes-dark.png) | ![Performance with unsupported energy shown](docs/screenshots/performance-dark.png) |

| Settings, Light | Settings, Dark |
| --- | --- |
| ![Settings in Light appearance](docs/screenshots/settings-light.png) | ![Settings in Dark appearance](docs/screenshots/settings-dark.png) |
