# Microgravity

Microgravity is a native macOS 14+ process and system monitor. Its sidebar provides Processes, Performance, App History, Startup, Users, Details, Services, and Settings. Startup and Services are read-only inventories; process actions target the selected process identity and Force Quit asks for confirmation.

## Build

Install Xcode and Node.js 22.12 or newer, then run `npm ci` and `npm run build:debug`. The unsigned development app is written to `DerivedData/Build/Build/Products/Debug/Microgravity.app`. Use `npm run test:all` for the repository's checks; native UI tests require a working macOS GUI/XCTest session. Signing and distribution are described in [docs/RELEASING.md](docs/RELEASING.md).

## Data and permissions

The app collects local process and system measurements and stores aggregate history locally for up to 30 days. Settings can pause sampling and reset history. Optional helper, login item and update features report their availability in Settings and may require macOS approval. Some metrics and inventory locations can be unavailable or incomplete due to platform support or permissions; the interface identifies those states rather than treating them as zero or an empty inventory.

This project is under development. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for verification and remaining release evidence.
