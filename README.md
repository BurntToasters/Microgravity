# Microgravity

Microgravity is a native macOS 14+ process and system monitor. Its sidebar provides Processes, Performance, App History, Startup, Users, Details, Services, and Settings. Startup and Services are read-only inventories; process actions target the selected process identity and Force Quit asks for confirmation.

## Build

Install Xcode and Node.js 22.12 or newer, then run `npm ci` and `npm run build:debug`. The unsigned development app is written to `DerivedData/Build/Build/Products/Debug/Microgravity.app`. The non-UI checks and the Core XCTest suite run without a GUI session; the command list is in [docs/RELEASING.md](docs/RELEASING.md). `npm run test:all` also runs the UI XCTest target, which needs a logged-in desktop session and Automation Mode and has not passed for 0.1.0. Signing and distribution are described in [docs/RELEASING.md](docs/RELEASING.md) as well.

## Data and permissions

The app collects local process and system measurements and stores aggregate history locally for up to 30 days. Settings can pause sampling and reset history. Optional helper, login item and update features report their availability in Settings and may require macOS approval. Some metrics and inventory locations can be unavailable or incomplete due to platform support or permissions; the interface identifies those states rather than treating them as zero or an empty inventory.

Microgravity 0.1.0 has not been released. The Core test suite and the build gates pass on the development host. Signed UI tests, the manual UI checklist, notarized distribution, and update delivery are not yet verified. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for what was checked and how, and for the known gaps.
