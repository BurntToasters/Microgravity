# Native UI acceptance

The app is a native AppKit process and system monitor for macOS 14 and later. It
uses the system appearance by default and consumes timestamped snapshots from the
core layer. Production UI must never invent process, device, capability, or
history values. Fixture data is enabled only in a Debug UI-test runner, with
both the UI-test launch argument and XCTest environment marker present; the
argument alone cannot switch a production build to fixture data.

## Shell and navigation

- Use a resizable native window with a persistent navigation sidebar for
  **Processes**, **Performance**, **App History**, **Startup**, **Users**,
  **Details**, **Services**, and **Settings**.
- Closing the last window terminates the app. No storyboard or SwiftUI is used.
- Sidebar items, tables, headers, graph controls, actions, and dialogs have
  stable accessibility identifiers and keyboard focus/activation behavior.
- Selection remains attached to a stable process identity as rows are sorted or
  refreshed. Removing/replacing a PID must clear or explicitly invalidate the
  old selection.

## Processes and Details

- Processes is a searchable, sortable, resizable table with subtle resource
  heatmaps. Related processes appear as expandable parent groups; expanding a
  group shows its children and selecting any row exposes its stable identity.
- Details is a flat process inventory showing PID, owner, parent PID, executable
  path, CPU, memory, disk, available network and GPU columns. Unsupported fields
  are labeled unavailable; they are never presented as zero.
- Quit asks the core to act on the selected stable identity. Force Quit requires
  confirmation. The core must revalidate that identity at action time; if the
  PID was reused or the target exited, the UI reports that and refreshes. Neither
  action recursively targets child processes.

## Performance and history

- Performance shows timestamped CPU total and per-core activity, memory pressure
  and swap, disk and network throughput, and GPU/energy only when supported.
  Graphs label units and provide a short definition. Unsupported and temporarily
  unavailable metrics have distinct states from a measured zero.
- Pausing sampling retains the last sample and labels it as paused/stale. The
  configured refresh interval is 0.5, 1, 2, or 5 seconds.
- App History displays at most 30 days of measured application totals. Missing
  samples are shown as gaps, not interpolated as zero. Reset is explicit and
  confirmed; history reset does not clear process or operating-system state.

## Read-only inventory

- Startup and Services are inspection surfaces only. They show discovery
  completeness, item/service identity, and known executable path. The UI may
  reveal a path in Finder or open the relevant System Settings pane when the
  integration supports it; it does not enable, disable, start, or stop items.
- Users displays active sessions and per-user process/resource aggregates. It
  offers no account-management action.
- Incomplete discovery is visible on each relevant page. An empty list is not
  presented as proof that there are no items when collection failed or is
  unsupported.

## Settings and integrations

- Settings exposes System/Light/Dark appearance, the four refresh intervals,
  pause/resume, confirmed history reset, and the helper, login-item, and update
  integration states.
- Helper setup and removal, login-item control, and updates are routed through an
  integration protocol. Controls display unavailable, failure, and approval states
  rather than implying success.
- Unsupported settings and metrics remain visible with a reason where possible.

## Failure-first test cases

The XCTest UI suite launches with `--ui-test-fixtures`; production launches use
the live data provider only. UI tests must cover these failure scenarios before
the corresponding surface is considered complete:

1. PID reuse or process exit between selection and Force Quit: confirmation is
   dismissed, no replacement process is targeted, and stale selection clears.
2. A child process refreshes while its parent group is collapsed/expanded:
   grouping remains correct and selection does not jump to a different PID.
3. Search or sorting changes visible order while a row is selected: identity is
   preserved, or selection is explicitly cleared if the process disappeared.
4. GPU/energy collection is unsupported or collection fails: UI does not render
   a zero-valued graph and states the capability/error separately.
5. A sample is absent in the 30-day history window: a visible gap remains and
   totals do not count the gap as zero.
6. Startup/service discovery is denied or incomplete: UI reports incomplete
   discovery and does not imply that the inventory is empty.
7. Action integration is unavailable: process controls are disabled or explain
   why; fixture mode never invokes a host process action.
8. The last window closes: the app exits rather than remaining in the Dock.

The deterministic fixture suite captures an XCTest screenshot attachment for
each principal navigation page. Attachments belong to the `.xcresult` bundle
produced by the native test scheme.

These are acceptance criteria, not a claim of completed manual or hosted validation.
