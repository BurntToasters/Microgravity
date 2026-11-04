# Implementation status

Last verified: 2026-11-04 on macOS 27.2, Xcode 27.2, arm64, Node.js 26.13.0.

Microgravity has native AppKit monitoring surfaces backed by the local collector,
with explicit unavailable and incomplete states. Optional helper, login-item, and
updater controls depend on platform configuration and approval. See
[UI acceptance](UI_ACCEPTANCE.md) for intended behavior and
[core failure cases](FAILURE_CASES_CORE.md) for collector, history, and action
regressions.

## Verified on the authoring host

| Gate | Command | Result |
| --- | --- | --- |
| Repository validation | `npm run validate` | pass |
| Node tests | `npm run test:node` | 19 passed, 0 failed |
| Debug build | `npm run build:debug` | pass; unsigned development app at `DerivedData/Build/Build/Products/Debug/Microgravity.app` |
| Release smoke build | `npm run build:release-smoke` | pass; unsigned universal (`arm64 x86_64`) Release compile |
| Core XCTest | `-only-testing:MicrogravityCoreTests` | 44 passed, 0 failed |
| UI XCTest | signed `npm run test:all` | **blocked before tests**: signed runner launches, then fails at Automation Mode authentication (`com.apple.LocalAuthentication Code=-2 "Canceled by user."`) |

The Debug configuration disables the hardened runtime so the ad-hoc development
app can load the embedded Sparkle framework without a Team ID mismatch. The
Release configuration keeps the hardened runtime.

## Remaining verification

The 13 native UI tests require Automation Mode. On the authoring host the UI
runner reaches the XCTest initialization and then fails with
`com.apple.LocalAuthentication Code=-2 "Canceled by user"` because the host is in
closed-clamshell mode and cannot complete biometric authentication. The exact
administrator step and a self-contained VM handoff are in
[`TASK.md`](../TASK.md).

Still unverified:

- signed Developer ID distribution, notarization, and stapling;
- Sparkle update delivery from a real appcast;
- privileged helper authorization against the live daemon;
- VoiceOver and full keyboard-only operation;
- long-running real-world performance and memory behavior;
- light/dark appearance and window resizing on physical displays.

A successful compile or focused automated test does not establish any of those.
Release requirements are tracked in [RELEASING.md](RELEASING.md).
