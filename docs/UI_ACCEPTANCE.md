# Native UI acceptance

The app is a native AppKit process and system monitor for macOS 14 and later. It
uses the system appearance by default and consumes timestamped snapshots from the
core layer. Production UI must never invent process, device, capability, or
history values. Fixture data is enabled only in a Debug UI-test runner, with
both the UI-test launch argument and XCTest environment marker present; the
argument alone cannot switch a production build to fixture data.

## Shell and navigation

- Use a resizable native window. It opens at 1280 × 820, cannot be resized below
  960 × 600, and saves its frame between launches.
- The window has a unified toolbar with page-specific items and a source-list
  sidebar. The sidebar has two groups: **Monitor** (Processes, Performance, App
  History) and **Inventory** (Startup, Users, Details, Services), with Settings
  last. A status footer shows either "Paused" or the sampling interval, and the
  time of the last sample.
- Command-1 through Command-8 select the sidebar pages in sidebar order.
  Command-Option-S toggles the sidebar. Settings is also available as
  Command-comma.
- The menu bar has the standard application, File, Edit, View, Window, and Help
  menus, a Process menu for the selected process, and Check for Updates.
- Closing the last window terminates the app. No storyboard or SwiftUI is used.
- Sidebar items, tables, outline rows, headers, graph controls, toolbar items,
  actions, and dialogs have stable accessibility identifiers and keyboard
  focus/activation behavior.
- Selection remains attached to a stable process identity as rows are sorted or
  refreshed. Removing or replacing a PID clears or explicitly invalidates the
  old selection.
- Confirmations (Force Quit, Reset History, and similar) are sheets attached to
  the window that raised them, not app-modal alerts.

## Processes and Details

- Processes is a native outline view. It is searchable and sortable, with app
  icons, subtle heat-mapped resource cells, and a grouping choice of **Group by
  App** or **Flat List**. In grouped mode, related processes appear under an
  expandable parent row. Expanded groups are remembered across launches by full
  PID-plus-start-time identity, so a reused PID never inherits old expansion.
  Selecting any row exposes its stable identity. **Show in Details** opens the
  flat inventory and selects that same full process identity when it is still
  present.
- Partial and unavailable readings are marked with a badge and a tooltip that
  gives the reason. A selection bar at the bottom of the page shows the selected
  process and its available actions.
- Details is a flat process inventory showing PID, owner, parent PID, executable
  path, CPU, memory, disk, available network and GPU columns. Unsupported fields
  are labeled unavailable; they are never presented as zero.
- Quit asks the core to act on the selected stable identity. Force Quit requires
  confirmation in a window sheet. The core must revalidate that identity at
  action time; if the PID was reused or the target exited, the UI reports that
  and refreshes. Neither action recursively targets child processes.
- Rejections explain the reason in plain language. A process that belongs to
  another user, or a system process, is described as protected rather than as an
  error in the app.

## Process action policy (privileged helper)

This is the policy for signalling processes after the user approves the
privileged helper. It was a deliberate decision for 0.1.0; the implementation
and the Settings caption must match it.

- The helper can quit processes owned by other standard users (non-root owners).
- The helper cannot signal root-owned processes, PID 1, or processes whose
  executable path is under `/System/Library/`, `/usr/libexec/`, `/usr/sbin/`, or
  `/sbin/`. A process whose executable path cannot be read is also treated as
  protected, and so is any process the OS flags as a system process.
- The helper never signals its own process or the requesting client.
- Settings states the limit: "Lets you quit processes owned by other standard
  users. System and root processes stay protected."
- Widening this policy is a product decision. It requires updating this section,
  the Settings caption, and the helper policy tests together.

## Performance and history

- Performance shows timestamped CPU total and per-core activity, memory pressure
  and swap, disk and network throughput, and GPU/energy only when supported. A
  metric rail with sparklines selects the detail graph. Graphs have a fill, grid
  lines, axis labels, and a time-window picker. Missing samples are drawn as gap
  markers. Each graph labels its units and gives a short definition.
  Unsupported and temporarily unavailable metrics have distinct states from a
  measured zero.
- Network totals exclude loopback, virtual, and tunnel interfaces. Those
  interfaces remain in the per-interface list and are marked as excluded from
  totals.
- CPU percentages are normalized across logical cores: a process consuming one
  full core reports `100 / N` percent on an N-core system, and a fully saturated
  system totals approximately 100 percent.
- Pausing sampling retains the last sample and labels it as paused/stale. The
  configured refresh interval is 0.5, 1, 2, or 5 seconds.
- App History is one outline of applications and days. It displays at most 30
  days of measured application totals. Missing samples are shown as gaps, not
  interpolated as zero. Reset is explicit and confirmed in a window sheet;
  history reset does not clear process or operating-system state.
- Pre-release builds recorded per-app CPU seconds in the wrong unit. Histories
  from those builds must be reset before their CPU values are relied on.

## Read-only inventory

- Startup and Services are inspection surfaces only. They show discovery
  completeness, item/service identity, status, item kind, and known executable
  path. The only actions are Reveal in Finder and Open Login Items Settings; the
  UI does not enable, disable, start, or stop items.
- Users displays active sessions and per-user process/resource aggregates. A
  small **You** badge sits beside the current user's name in the User column;
  sorting uses the bare short name. It offers no account-management action.
- Incomplete discovery is visible on each relevant page. An empty list is not
  presented as proof that there are no items when collection failed or is
  unsupported.

## Settings and integrations

- Settings is a System Settings–style form. It exposes System/Light/Dark
  appearance, the four refresh intervals, pause/resume, confirmed history reset,
  and the helper, login-item, and update integration states.
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

The final signed UI XCTest run on 2026-11-07 executed 18 tests: 15 passed and 3
failed. Failures cover two snapshot-refresh waits and history numeric-sort
ordering. See `docs/RELEASING.md` for details. The full suite has not completed
with zero failures; these acceptance criteria do not claim completed manual or
hosted validation.
