# Implementation status

Microgravity has native AppKit monitoring surfaces backed by the local collector, with explicit unavailable and incomplete states. Optional helper, login item and updater controls depend on platform configuration and approval. See [UI acceptance](UI_ACCEPTANCE.md) for intended behavior and test cases.

This is development software. A successful compile or focused automated test does not establish signed distribution, notarization, update delivery, helper authorization, or real-world performance and accessibility. Native GUI tests, VoiceOver and keyboard operation, window resizing, light and dark appearances, and signed packaged-app behavior require verification in a suitable macOS session. Release requirements are tracked in [RELEASING.md](RELEASING.md).
