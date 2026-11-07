# Microgravity 0.1.0 — UI and code audit, with implementation plan

**Audience:** the agent implementing this plan.
**Instruction to that agent:** delete this file (`plan.md`) from the repository root once every item you choose to implement is done and verified. Do not commit it as part of the release.

Audit date: 2026-11-06, against commit `2cd7618` (clean tree). Evidence used:

- Full read of every file under `Sources/`, `Tests/`, `scripts/`, `config/`, `docs/`, `.github/`, and the root metadata files.
- A Debug build (`npm run build:debug`, passes) launched on an Apple M5 Pro (virtual), 16 logical cores, macOS 27.2. Screenshots of the live Processes page in light and dark appearance, plus XCTest screenshot attachments from earlier UI runs under `DerivedData/TestResults`.
- One micro-benchmark to confirm the process-CPU unit bug (see C1).

Everything stated as a defect below was verified against the code or by observation. Items marked "verify" were not fully confirmed.

---

## 0. Executive summary

The architecture is sound and unusually honest about missing data (unavailable is never zero), the core layers are well tested (121 Core XCTests across 16 files), and the release tooling is thorough. The gaps are concentrated in three places:

1. **One critical metric bug.** Per-process CPU is computed from `proc_taskinfo` as if the values were nanoseconds. On Apple Silicon they are Mach ticks (timebase 125/3), so every process, group, user aggregate and per-app CPU history is about **41.7× too low**. The live app shows 0.0% for everything. Fix is small (C1).
2. **The UI is functional but reads as a prototype.** Plain title bar, a hand-rolled sidebar with no visible selection, bordered tables that overflow horizontally at the default window size, a window that opens at its minimum size, inline debug strings (`pid=… start=…`, `0.0% · partial…`), app-modal alerts, no app icons in process rows, graphs with no axes or fills. None of it is wrong, but none of it looks like Windows 11 Task Manager or a macOS 14 app. Section 2 is a full design target and a phased plan.
3. **Release readiness.** The 13 UI tests have never passed on any host, two VM-session handoff files are tracked in git, status docs claim uncommitted changes that are now committed, and the changelog entry is a placeholder.

Recommended order: C1 and the window-size fix first (one day, high user-visible value), then the UI shell (toolbar + sidebar), then the Processes outline view, then Performance, then the rest.

---

## 1. Design target: "Windows 11 Task Manager, built like a macOS 14 app"

This is the visual and interaction contract every UI change below should serve. Where Task Manager and macOS conventions conflict, macOS wins on chrome (window, sidebar, controls, fonts, colors) and Task Manager wins on information design (what is shown, heat-mapping, performance page layout, page structure).

### 1.1 Window and chrome

- `NSWindow` with `styleMask` including `.fullSizeContentView`; `titlebarAppearsTransparent = true`; `titleVisibility = .hidden`; `toolbarStyle = .unified`. The sidebar's `NSVisualEffectView` then extends under the title bar like Finder, Mail, System Settings, and Activity Monitor.
- One `NSToolbar` (delegate on the window controller). Items, left to right: `NSToolbarItem.Identifier.toggleSidebar`, `NSTrackingSeparatorToolbarItem` bound to the split view's divider index 0, flexible space, then **page-specific items** supplied by the current page controller (see 1.4). Standard `NSSearchToolbarItem` for pages that search.
- Default size 1280×820, minimum 960×600, `setFrameAutosaveName("Main")`. Sidebar 200–280 pt, collapsible with the toolbar button and ⌘⌥S (the `toggleSidebar(_:)` responder action gives this for free).
- Window title stays "Microgravity" for the Dock and ⌘-Tab; do not render the app name in the sidebar.

### 1.2 Sidebar

- `NSOutlineView` configured as a source list (`style = .sourceList`, `selectionHighlightStyle = .sourceList`, `rowSizeStyle = .default`, floats group rows). Two groups: **Monitor** (Processes, Performance, App History) and **Inventory** (Startup, Users, Details, Services). **Settings** sits in its own bottom-anchored row or as the last item; also reachable with ⌘,.
- Each row: SF Symbol (`.sidebar` symbol scale via `NSImage.SymbolConfiguration(scale: .medium)`) + title. Keep the current symbol choices; they are good.
- Keyboard: ⌘1…⌘8 switch pages (add a **View** menu that lists them). Arrow keys move selection in the sidebar.
- Footer: a two-line status cell at the bottom of the sidebar: "Sampling every 1 s" / "Updated 9:23:30 PM" (or "Paused · last sample …"). This replaces both the per-page "Updated …" label and the "Local system data" caption.
- Accessibility identifiers must remain `navigation.item.<page>` on the row's cell view so the UI tests keep working.

### 1.3 Page layout

- Each page is an `NSViewController` filling the detail area. Horizontal insets 20 pt, top inset 12 pt below the toolbar.
- Page header: title in `NSFont.systemFont(ofSize: 22, weight: .bold)` (Task Manager's page title weight), optional one-line caption in 11 pt secondary. Drop the long explanatory sentences; move explanations to tooltips or a help button where they matter.
- A **status banner** component (used by Startup, Services, Users, History, Details, Performance): a rounded 8 pt bar with an SF Symbol (`info.circle`, `exclamationmark.triangle`), one line of text, optional trailing button. Tints: `.secondaryLabelColor` on `.quaternarySystemFill` for informational, `.systemOrange` tint for incomplete/degraded, `.systemRed` for failed. This replaces the loose `NSTextField` state labels (`*.discovery-state`, `*.capability-state`); keep those accessibility identifiers on the banner's text field.
- Cards (Performance, Settings): `controlBackgroundColor` fill, 1 pt `separatorColor` stroke, 10 pt radius. The existing `CardContainerView` is fine; keep it.

### 1.4 Page toolbar items (Task Manager puts actions in the header; we put them in the unified toolbar)

| Page | Toolbar items (trailing) |
| --- | --- |
| Processes | search field, "Quit" button, "Force Quit…" button (both enabled only with a valid selection), overflow menu (Group by app / Flat) |
| Performance | "Pause"/"Resume" toggle, refresh-interval pop-up (0.5 s, 1 s, 2 s, 5 s) |
| App History | "Reset History…" |
| Details | search field |
| Startup / Services | "Reveal in Finder", "Open Login Items Settings" |
| Users, Settings | none |

Implement with a `PageToolbarProviding` protocol on page controllers (`var toolbarItemIdentifiers: [NSToolbarItem.Identifier]`, `func toolbarItem(for:)`), and have the window controller rebuild trailing items on page change.

### 1.5 Tables and the Processes outline

- Processes becomes an `NSOutlineView` (not a flat `NSTableView` with a fake disclosure button). Groups are parent items; children indent natively; disclosure triangles animate; ←/→ collapse/expand; `autosaveExpandedItems` keyed by stable identity.
- Table style `.inset` (rounded selection like Finder on macOS 11+), no `.lineBorder` on the scroll view, row height 28, `intercellSpacing` (0, 0), `usesAlternatingRowBackgroundColors = true` (Activity Monitor convention; acceptable alongside heat-mapping as long as the heat fill is applied over the alternate color).
- Name column: 16 pt app icon (`NSWorkspace.shared.icon(forFile: bundlePath)` for app groups, `NSWorkspace.shared.icon(for: .unixExecutable)` for plain executables), then name. Group title bold is fine. Keep `process.group.<slug>` / `process.row.<pid>` identifiers on the name text field.
- Numeric columns right-aligned, `monospacedDigitSystemFont`, header alignment matches cell alignment. Column autosave name so widths persist. Default widths must fit at 1280 wide without a horizontal scroller; GPU and Network columns hidden by default when the capability is unavailable (header context menu to show/hide columns like Activity Monitor).
- **Heat map:** fill the entire cell rect (not the text field's bounds). Ramp: `NSColor.systemOrange.withAlphaComponent(a)` where `a = 0` below 1% and rises to 0.45 at 100% of the column maximum, using a perceptual curve (`a = 0.45 * pow(intensity, 0.6)`). Memory ramps against physical memory; CPU against 100%; disk and network against the current column maximum. Task Manager's yellow→orange→red ramp works on white; on macOS use a single hue with alpha so it survives dark mode and the alternate-row color. Selected rows do not draw heat.
- **Partial / unavailable:** never put "· partial · 3 of 5 members unavailable" into a value cell. Show the number, append a small `exclamationmark.triangle` (orange) or `questionmark.circle` (secondary) image on the trailing edge, and put the detail in the cell's tooltip and accessibility description. Unavailable values render as "—" with the reason in the tooltip; the Details page may keep the full "Unavailable · reason" text since that page's purpose is explicitness.
- Selection detail: remove the `pid=… start=…` block under the table. Replace with a slim bottom bar: app icon, name, "PID 410 · dev · /Applications/…", and the two action buttons when the toolbar is collapsed. Keep `process.selection.identity` as the accessibility identifier of the PID label, with the label text still containing `pid=<n>` (the UI tests assert on it), e.g. "pid=410 · started 2026-11-06 21:23:11".
- Context menu: Quit, Force Quit…, separator, Reveal in Finder, Copy Path, Show in Details.
- Shortcuts: ⌘F focuses search (also the toolbar search field), ⌘⌥Q Quit Process, ⌘⌥⇧Q Force Quit (Activity Monitor's bindings), ⌘I Show in Details.

### 1.6 Performance page (Task Manager layout)

Master–detail, implemented as a horizontal `NSSplitView` (or a fixed 240 pt left column):

- **Left rail:** one row per metric — CPU, Memory, Disk, Network, GPU, Energy — each with title, current value line ("12% · 3.1 GHz" style; use what we have: "12%", "9.4 GB / 24 GB", "R 1.2 MB/s · W 340 KB/s", "↓ 2.1 MB/s · ↑ 180 KB/s"), and a 36 pt sparkline of the last 60 samples. GPU and Energy rows show "Unavailable" in secondary text with no sparkline when the capability is off, never a flat zero.
- **Right detail:** large card with metric title, subtitle ("% Utilization over 60 seconds"), the big graph (min 240 pt tall), then a stats grid (`NSGridView`, 2–3 columns) of the per-metric facts: CPU → utilization, logical cores, processes, threads if cheap to get, uptime; Memory → used, available, wired/compressed if exposed, swap used/total, pressure; Disk → read/write rates and totals; Network → per-interface rows (name, up/down, totals); GPU/Energy → provider-reported fields and the capability reason.
- CPU detail offers a segmented control "Overall / Logical processors"; the latter shows a grid of mini graphs (one per core), which is the Task Manager feature people recognize. Keep the `performance.cpu-core.<n>` identifiers on each mini graph.
- **Graph style:** 1.5 pt line, gradient fill under the line (color at 0.25 alpha → 0.02), grid lines at 25/50/75%, light axis labels ("100%", "0", "60 s", "0"), gaps rendered as breaks with a hatched or dotted segment marker and a tooltip "Sample gap · paused". Colors follow Task Manager's assignment but through system colors: CPU `.systemBlue`, Memory `.systemPurple`, Disk `.systemGreen`, Network `.systemOrange`, GPU `.systemTeal`, Energy `.systemYellow`. Throughput graphs plot two series (read/write, down/up) with the second series in a lighter tint of the same hue, as Task Manager does.
- The window of samples is time-labelled. Graph samples are capped at 720; at 0.5 s that is 6 minutes, at 5 s one hour. Label the axis with the real span and let the user pick "Last 60 s / 5 min / All" in the detail card header.

### 1.7 App History, Details, Users, Startup, Services

- App History: single table with app icon, name, CPU time, disk read/write, network (two columns), coverage. Day-level detail moves to a disclosure per app (outline view) or a "By day" segmented view; both tables stacked is too dense. Keep row identifiers `history.total.<slug>`, `history.day.<day>.<slug>`, `history.gap.<day>.<slug>` so tests continue to pass.
- Details: keep the flat table, add icons, use `.inset` style, hide GPU/Network columns when unavailable, add the status banner for capability state.
- Users: icon per user (`NSImage(systemSymbolName: "person.crop.circle")`), "(You)" rendered as a small secondary badge, not in the name string.
- Startup/Services: a **status column with a colored dot** (green running, grey unknown, orange stopped) plus text; a "Kind" column with human labels (Login Item, Launch Agent, Launch Daemon); the coverage banner at the top; the selected item's path shown in the bottom bar with "Reveal in Finder".

### 1.8 Settings

Match System Settings 14 forms rather than radio rows:

- Appearance: `NSPopUpButton` (System / Light / Dark) or a 3-segment `NSSegmentedControl`. Keep identifiers `settings.appearance.<mode>` on the menu items or segments.
- Refresh interval: `NSPopUpButton` with the four values; identifiers `settings.refresh.<value>`.
- Sampling: a single "Pause Sampling / Resume Sampling" push button with the status caption beside it (already close).
- History: "Reset App History…" push button with a caption "History is kept for 30 days."
- Open at Login: `NSSwitch` bound to the login-item state, with the "Requires approval" case rendering the switch off + a "Open Login Items Settings…" link button.
- Privileged helper and Software updates: status text with a leading dot (green available / grey not configured / orange requires approval / red failed) and the action buttons. Also add "Check for Updates…" to the application menu (Sparkle convention).
- Layout with `NSGridView`: right-aligned labels in column 0, controls in column 1, 8 pt row spacing, cards per section. All confirmation dialogs become sheets (`beginSheetModal(for: window)`).

### 1.9 Typography, color, motion, accessibility

- Fonts: system only; sizes 22/13/12/11; numbers in monospaced-digit variants. Never hard-code a color — use `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `controlBackgroundColor`, `windowBackgroundColor`, `separatorColor`, `controlAccentColor`, and `system*` hues for data.
- Honor `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (disable outline animations and graph easing) and `accessibilityDisplayShouldIncreaseContrast` (bump heat-map alpha and graph line width).
- Every control keeps or gains a stable accessibility identifier; the list in `Tests/UITests/MicrogravityUITests.swift` is the contract. When an identifier must move to a different view class (e.g. from `NSButton` to an outline row), update the test's lookup helper, not the identifier string.

---

## 2. UI audit findings (current implementation) and the plan

Severity: **P1** blocks a credible 0.1.0 look; **P2** visibly rough; **P3** polish.

### 2.1 Shell and window

| # | Sev | Finding | Where | Fix |
| --- | --- | --- | --- | --- |
| U1 | P1 | Window opens at its **minimum size (920×560)**, not the intended 1280×820. The content view controller is assigned after `init`, and its root view has no intrinsic size, so AppKit shrinks the window to `minSize`. No frame autosave, so the user's resize is also lost on relaunch. Observed live (window bounds 920×560 on a 2560-wide display). | `Sources/App/AppDelegate.swift:84-93` | Set `window.contentViewController` first, then `window.setContentSize(NSSize(width: 1280, height: 820))`, then `window.center()`; add `window.setFrameAutosaveName("Main")`. Or give `RootViewController` a `preferredContentSize`. Add a Core test that asserts the window's content size after `MainWindowController` init. |
| U2 | P1 | Standard opaque title bar; the sidebar's `NSVisualEffectView` stops under the title bar. No toolbar. Does not read as a macOS 14 sidebar app. | `AppDelegate.swift:83-88`, `AppShellViewController.swift:118-125` | Implement 1.1 and 1.4. |
| U3 | P1 | Sidebar is a stack of borderless toggle `NSButton`s. The **selected page has no visible selection highlight** (borderless toggle buttons draw nothing for `.on`); confirmed in screenshots. No keyboard navigation, no collapse. | `AppShellViewController.swift:117-215` | Replace with the source-list `NSOutlineView` from 1.2. |
| U4 | P2 | "MICROGRAVITY / SYSTEM MONITOR" uppercase brand block and "Local system data" footer are non-native and waste 90 pt of the sidebar. | `AppShellViewController.swift:132-137, 155-158` | Remove; use the status footer from 1.2. |
| U5 | P2 | Sidebar thickness fixed 205–265 and `canCollapse = false`; content minimum 650. | `AppShellViewController.swift:79-84` | 200–280, collapsible; content minimum 700. |
| U6 | P2 | Main menu has no View menu (page switching), no Help menu, no "Check for Updates…", no Settings (⌘,). Edit menu uses `NSText` selectors that do not route to the search field's field editor for Select All in some cases. | `AppDelegate.swift:30-80` | Add View (pages ⌘1–8, Toggle Sidebar ⌘⌥S), Window (standard), Help; add "Check for Updates…" and "Settings…" (⌘,) to the app menu. |
| U7 | P3 | Page header title is 25 pt semibold with a two-line explanatory caption on every page. | `AppShellViewController.swift:286-300` | 22 pt bold, optional one-line caption (1.3). |

### 2.2 Processes

| # | Sev | Finding | Where | Fix |
| --- | --- | --- | --- | --- |
| U8 | P1 | Columns overflow at the default width: a horizontal scroller shows, the Memory header is cut to "Me", values truncate ("3.45 G"). Caused by U1 plus fixed widths summing to 1084 pt inside a 650 pt minimum. | `ProcessesViewController.swift:170-190` | After U1, make Name the resizing column, set `columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle` or `.uniformColumnAutoresizingStyle`, hide GPU/Network when unavailable, persist widths with `autosaveName`. |
| U9 | P1 | Heat map draws a **grey/orange pill behind every value** including 0% (base alpha 0.025 plus a 4 pt corner radius on the text field's layer), so every CPU/Memory cell looks like a disabled button. Task Manager fills the whole cell with a transparent-at-zero ramp. | `ProcessesViewController.swift:442-455, 707-725` | Fill the cell view (not the label) in `ProcessValueCellView.draw`, ramp per 1.5, no fill for selected rows. |
| U10 | P1 | Partial/unavailable detail text is rendered inline ("0.0% · parti…") and truncated. | `UIFormatting.swift:27-30`, `ProcessesViewController.swift:404-427` | Badge + tooltip per 1.5. Add a `MetricCellPresentation` (value text, badge symbol, tooltip, accessibility description) type with unit tests. |
| U11 | P1 | Flat `NSTableView` with a custom chevron button standing in for disclosure. No indentation guides, no animation, no keyboard expand/collapse, no autosave of expanded groups; `toggleGroup` walks the superview chain to find its row. The full-table `reloadData()` on every snapshot (1 Hz) recreates every row view, which also makes synthesized clicks on the disclosure flaky (the documented UI-test failure). | `ProcessesViewController.swift:200-233, 371-399, 527-550, 630-690` | Migrate to `NSOutlineView` with a diffable update (`beginUpdates`, `insertItems`, `removeItems`, `moveItem`, then `reloadData(forRowIndexes:columnIndexes:)` for changed cells). Expanded set keyed by `ProcessIdentity`. Keep identifiers on the name field and the disclosure (`process.group.toggle.<slug>` can map to the outline's disclosure button via `outlineView(_:rowViewForRow:)`). |
| U12 | P2 | No app icons in rows. | `ProcessesViewController.swift:653-690` | Icon per 1.5; cache by bundle path in a small `NSCache`. |
| U13 | P2 | Selection block under the table shows `pid=410 start=2026-11-06 21:23:11.123` and a sentence; buttons are plain bezels below it. | `ProcessesViewController.swift:100-124, 471-495` | Bottom bar per 1.5; actions in toolbar. |
| U14 | P2 | Force Quit confirmation and error dialogs use `runModal()` (app-modal, detached from the window). Same in History, Settings, Inventory. | `ProcessesViewController.swift:566-575, 601-608`; `HistoryViewController.swift:180-187, 221-228`; `SettingsViewController.swift:259-266, 441-448`; `InventoryViewController.swift:183-189` | Sheets via `beginSheetModal(for:)` with async continuation; keep `process.force-quit.confirm` on the default button. |
| U15 | P2 | Search matches by lowercased `contains` on name/title/PID only; no match on executable path or bundle ID; children of a matching group are shown only if they match too (a group that matches by title shows all children — inconsistent with Details, which searches all columns). | `ProcessesViewController.swift:200-216` | Use `localizedStandardContains`, search name, path, PID, user; when the group matches, show all children. |
| U16 | P3 | `rowHeight = 30` here, 31 in `AccessibleTableModel`; `.lineBorder` scroll views everywhere. | `ProcessesViewController.swift:98,164`; `AccessibleTable.swift:74,216` | 28 pt, `.inset` style, no border. |
| U17 | P3 | Freshness label "Updated 9:23:30 PM" duplicated on Processes and Performance; wording "Paused · last sample …" fine. | `ProcessesViewController.swift:66-72`, `PerformanceViewController.swift:49-53` | Move to the sidebar footer (1.2); keep the `process.freshness` and `performance.sampling-state` identifiers on the footer label (tests read them). |

### 2.3 Performance

| # | Sev | Finding | Where | Fix |
| --- | --- | --- | --- | --- |
| U18 | P1 | Eight equal cards in a 2×4 grid, each with a 64 pt line graph, no axes, no fill, no time scale; nothing resembles Task Manager's rail + big graph. | `PerformanceViewController.swift:97-145, 262-275` | Rebuild per 1.6. Keep `performance.graph.*`, `performance.*.value`, `performance.*.state` identifiers on the equivalent elements. |
| U19 | P2 | "Pause Sampling" is a loose button under the header. | `PerformanceViewController.swift:55-58, 136` | Toolbar item (1.4). |
| U20 | P2 | Swap graph plots "Total" as a flat line next to "Used". Memory pressure graph plots a 0/1/2 step with a green line. | `PerformanceViewController.swift:188-205` | Swap: used/total as a capacity bar with a sparkline of used. Pressure: colored state chip (green/orange/red) with history as a thin colored timeline strip. |
| U21 | P2 | Per-core rows use `NSProgressIndicator` bars with a 250 pt minimum width; 16 cores push the card past the viewport. | `PerformanceViewController.swift:325-360` | Grid of mini graphs (1.6), 4–6 per row, adapts to width. |
| U22 | P3 | Eight hard-coded series colors for cores cycle after eight. | `PerformanceViewController.swift:161-166` | Single hue for the core grid; color only distinguishes series within one graph. |
| U23 | P3 | Graph background `quaternaryLabelColor.withAlphaComponent(0.06)`; grid lines `separatorColor` 0.35. Fine, but the graph has no inner padding on the top for the 100% label and no rounded clip. | `PerformanceViewController.swift:466-520` | Per 1.6 graph style; clip to 6 pt radius. |

### 2.4 Other pages

| # | Sev | Finding | Where | Fix |
| --- | --- | --- | --- | --- |
| U24 | P2 | App History stacks two full tables ("30-day totals", "Daily detail") each with a 150–160 pt minimum; both are cramped at 820 tall. | `HistoryViewController.swift:35-85` | Single outline (app → days) or segmented "Totals / By day". |
| U25 | P2 | Startup/Services: coverage reason sentences are joined with spaces into one long label; "Open System Settings" launches the Settings app root, not the Login Items pane. | `InventoryViewController.swift:132-143, 180-190` | Banner (1.3) with the first reason and a "Details…" popover listing all; open `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` or `SMAppService.openSystemSettingsLoginItems()`. |
| U26 | P2 | Settings uses three horizontal radio-button rows inside cards; integration rows force a 560 pt minimum width. | `SettingsViewController.swift:100-222` | Form per 1.8. |
| U27 | P3 | Users: "(You)" is baked into the sorted name string; aggregates recomputed per snapshot by filtering all processes per user. | `UsersViewController.swift:56-80` | Badge; group processes by UID once per snapshot. |
| U28 | P3 | Details: row ID is `details.process.<pid>`; identity is checked separately. Fine functionally; no icons, no column hiding. | `DetailsViewController.swift:66-123` | Icons, `.inset`, hide unavailable columns. |
| U29 | P3 | Empty states: tables are simply empty when nothing matches or discovery failed; the Inventory page only changes a caption. | all table pages | Centered placeholder view (symbol + title + caption) overlaid on the scroll view when `rows.isEmpty`. |
| U30 | verify | Dock/Finder icon: `Assets.car` is in the built bundle and `resources/microgravity.icon` exists, but `Info.plist` declares no `CFBundleIconName`. Confirm the icon shows in the Dock, the About panel, and the Force Quit dialog. | `Info.plist`, `scripts/generate-project.mjs` | If missing, set `ASSETCATALOG_COMPILER_APPICON_NAME` / `CFBundleIconName` in the generator and validate in `scripts/validate.mjs`. |

### 2.5 UI implementation plan (phased)

Each phase ends with `npm run validate && npm run test:node && npm run build:debug` plus the Core XCTest command from `docs/RELEASING.md`, and a manual light/dark screenshot of every page at 1280×820 and at the minimum size.

**Phase A — Shell (2–3 days).** U1, U2, U3, U4, U5, U6, U7, U17.
Files: `Sources/App/AppDelegate.swift` (window, toolbar, menus), new `Sources/UI/Shell/MainToolbar.swift`, new `Sources/UI/Shell/SidebarViewController.swift` (outline source list), `Sources/UI/AppShellViewController.swift` (page host, `PageToolbarProviding`, status footer wiring). Keep `DashboardPage` and `PageDependencies`.
Acceptance: window opens 1280×820 and restores position; sidebar selection pill visible in light and dark; ⌘1–8 and ⌘⌥S work; all 13 UI test identifiers still resolve (run the UI target at least in `build-for-testing`).

**Phase B — Processes (3–4 days).** U8–U16.
Files: `Sources/UI/ProcessesViewController.swift` → split into `ProcessesViewController.swift` (outline data source/delegate, diffing), `ProcessRowModel.swift` (pure row/diff logic, unit-testable), `ProcessCells.swift` (name cell with icon, value cell with heat fill and badge), `MetricCellPresentation.swift`. Update `Tests/CoreTests/UIStateTests.swift` to drive the outline view, and add tests for the diff (insert/remove/move preserve selection and expansion).
Acceptance: no horizontal scroller at 1280 wide; heat map transparent at 0; partial values show a badge with a tooltip; expand/collapse via click and keyboard; selection survives refresh, sort, search; CPU values are non-zero after C1.

**Phase C — Performance (3 days).** U18–U23.
Files: `Sources/UI/PerformanceViewController.swift` → `Performance/PerformanceViewController.swift` (split), `Performance/MetricRailView.swift`, `Performance/MetricGraphView.swift` (axes, fill, gaps, selectable window), `Performance/MetricDetailViewController.swift`, `Performance/CoreGridView.swift`. Preserve `ThroughputGraphPresentation` and its tests.
Acceptance: rail + detail; GPU/Energy unavailable rows never draw a zero series; gaps visible; identifiers preserved.

**Phase D — Inventory, History, Users, Details, Settings (3 days).** U24–U29, plus the banner and empty-state components in `Sources/UI/Components/`.

**Phase E — Polish (1–2 days).** Reduce Motion / Increase Contrast, tooltips, column autosave, keyboard shortcuts, VoiceOver pass with the Accessibility Inspector, screenshot set for the README.

---

## 3. Code audit findings

Severity: **Critical** = wrong results or data loss for users; **High** = user-visible defect or real risk; **Medium** = correctness/robustness under realistic conditions; **Low** = quality.

### 3.1 Critical

**C1 — Process CPU is ~41.7× too low on Apple Silicon (and wrong on any machine whose Mach timebase is not 1/1).**
`Sources/Collectors/SystemMonitorCollector.swift:428-434` treats `pti_total_user + pti_total_system` from `proc_taskinfo` as nanoseconds and divides by 1 000 000 000. Those fields are in Mach absolute-time units. Verified on this host: a 1.0 s busy loop advanced the counters by 23 999 645 units; `mach_timebase_info` is 125/3, so 23 999 645 × 125 / 3 = 0.99999 s. The live app shows 0.0% CPU for every process (screenshots), while `clock()` reports 1.0 s.
Consequences: every process row, every group aggregate (`makeGroup`), the Users page CPU column, the Processes CPU sort order and heat map, and per-application `cpu_seconds` in history (`SQLiteMonitoringHistoryStore.swift:recordApplicationTotals`, which multiplies group `cpuPercent` by elapsed) are wrong. System total CPU (`host_processor_info` ticks, lines 219-262) is correct, which is why the two disagree.
Fix: read `mach_timebase_info` once (`static let timebase`), convert `ticks * numer / denom` to nanoseconds before `processCounters.update`, i.e. store nanoseconds in the counter so deltas stay monotonic. Add `SystemMonitorCollectorTests.testCurrentProcessCPUPercentMatchesBusyLoop`: spin the current process for ~0.5 s between two `collect` calls and assert `cpuPercent ≈ 100 / capacityCores` within ±35%. Document the contract in `docs/FAILURE_CASES_CORE.md` (it already states the expected value but has no proof).
Also: existing per-app history rows written by 0.1.0-pre builds contain the wrong `cpu_seconds`; since the app has not shipped, no migration is needed, but mention it in the changelog if any tester has a database.

### 3.2 High

**H1 — Window opens at minimum size and forgets its frame.** See U1. `AppDelegate.swift:84-93`.

**H2 — Network throughput double-counts and includes loopback.** `Sources/Collectors/NetworkInterfaceReader.swift` returns every `RTM_IFINFO2` interface (lo0, gif, stf, anpi, bridge, utun, awdl, llw…), and `NetworkInterfaceCounterTracker.collect` sums them all into the system receive/transmit rates (`NetworkInterfaceReader.swift:150-180`). Loopback traffic (localhost servers, Docker, XPC over lo0) inflates "network" and utun/bridge interfaces count the same packets twice. Activity Monitor excludes loopback and virtual interfaces from its totals.
Fix: carry `ifm_flags` through `NetworkInterfaceCounter`; exclude `IFF_LOOPBACK` and interfaces whose type (`ifm_data.ifi_type`) is not Ethernet/Wi-Fi-like (`IFT_ETHER`, `IFT_IEEE80211`, `IFT_CELLULAR` where available), or at minimum exclude `lo*`, `utun*`, `gif*`, `stf*`, `anpi*`, `awdl*`, `llw*`, `bridge*`, `ap*` by name. Keep the per-interface list complete and add an `includedInTotals` flag so the Performance page can show which interfaces count. Add a parser test with a loopback record.

**H3 — Memory pressure is "Not collected" until the kernel sends an event.** `SystemMonitorCollector.swift:758-779` only learns the pressure level from a `DispatchSourceMemoryPressure` event; on a quiet machine no event arrives, so the Memory card shows "Not collected" indefinitely. `docs/FAILURE_CASES_CORE.md` requires initializing from an OS-reported state.
Fix: on each sample read `sysctlbyname("kern.memorystatus_vm_pressure_level")` (1 normal, 2 warning, 4 critical) as the baseline and let the dispatch source refine the timestamp; keep "unavailable" only when the sysctl fails.

**H4 — Snapshot publication waits on the SQLite write.** `Sources/Core/MonitoringStore.swift:98-130` awaits `historyStore.record` before `onSnapshot`, so UI latency includes a transaction with `BEGIN IMMEDIATE`, three retention deletes, and per-app upserts every sample. On a busy disk or with WAL checkpoints this delays and jitters the UI, and at the 0.5 s interval it can exceed the interval and skew `elapsed`.
Fix: publish the snapshot first (graph sample included), then record history asynchronously, keeping the generation guard and the `historyGapPending` semantics (the next record after a failed write still marks a gap). Throttle the retention `DELETE`s to once per UTC day (`SQLiteMonitoringHistoryStore.swift:148-151`).

**H5 — Sampling period drifts.** `MonitoringStore.swift:172-186` sleeps `interval` *after* `refreshNow()` returns, so the effective period is `interval + collection time` (collection is tens of milliseconds for ~600 processes, more with the helper). Rates remain correct because they use measured elapsed time, but graphs and the "every 1 s" claim are off and the UI test `refreshPulse` timing assumptions get looser.
Fix: compute the next deadline from the previous deadline (`deadline += interval`; if behind, skip ahead) and `Task.sleep(until:)` on a `ContinuousClock`.

**H6 — The UI test suite has never passed, yet `docs/RELEASING.md` calls it a mandatory release gate.** `Tests/UITests/MicrogravityUITests.swift` (13 tests) fails on synthesized-event delivery per `docs/IMPLEMENTATION_STATUS.md`. Either (a) get it green on a physical Mac with Automation Mode (the outline-view migration in Phase B removes the custom disclosure button that is the hardest target), or (b) state honestly in RELEASING.md and IMPLEMENTATION_STATUS.md that the UI gate is Core XCTest view-controller tests plus a manual checklist for 0.1.0. Do not ship docs that describe a gate that cannot run.

**H7 — Stale and session-specific files are tracked.** `TASK.md` and `TEST_RESULTS.md` are VM-session handoffs referencing `/tmp/microgravity-*.log` files and sudo steps; `docs/IMPLEMENTATION_STATUS.md` has an "Uncommitted changes" section describing changes that are now in commit `2cd7618`; `CHANGELOG.md` for 0.1.0 reads "Initial public release foundation."; `README.md` says "This project is under development."
Fix: delete `TASK.md` and `TEST_RESULTS.md` (move anything durable into `docs/`), rewrite IMPLEMENTATION_STATUS to the current verified state, write real 0.1.0 release notes (the changelog test in `scripts/tests/changelog.test.mjs` enforces the format), and update the README's status sentence and add screenshots.

### 3.3 Medium

**M1 — Every snapshot rebuilds every row view.** `ProcessesViewController.swift:220` (`reloadData()`), `AccessibleTable.swift:94,129`, and `rowViewForRow` allocates a new `NSTableRowView` per call (`ProcessesViewController.swift:401-407`, `AccessibleTable.swift:118-124`) instead of `makeView(withIdentifier:owner:)`. Cost grows with visible rows × columns per second and breaks hover/press state. Fixed by U11's diffing; for the `AccessibleTableModel` tables, diff by row ID and use `reloadData(forRowIndexes:columnIndexes:)` with reused row views.

**M2 — Per-process syscall volume.** `collectProcesses` (`SystemMonitorCollector.swift:398-500`) performs `proc_pidinfo(PROC_PIDTBSDINFO)` twice, `PROC_PIDTASKINFO`, `proc_pid_rusage`, `proc_name`, and `proc_pidpath` for every PID every interval (~6 × 600 = 3 600 syscalls/s at 1 Hz, 7 200 at 0.5 Hz). Name and path are immutable for a given `ProcessIdentity`; cache them keyed by identity and evict with `processCounters.retain`. `Bundle(url:)` metadata is already cached (good).

**M3 — Settings reaches into ServiceManagement directly.** `SettingsViewController.swift:383-391` calls `SMAppService.daemon(...)` to decide whether "Remove Helper" is enabled, bypassing `SystemIntegrationAPI` and executing in fixture mode. Add `canRemoveHelper` (or a `helperRegistered: Bool`) to `SystemIntegrationStatus` and implement it in `NativeSystemIntegrationAPI`.

**M4 — "Open System Settings" opens the wrong place.** `InventoryViewController.swift:181-189` opens the System Settings app root. Use `SMAppService.openSystemSettingsLoginItems()` (already used by the integration API) or the `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` URL.

**M5 — Privileged helper cannot terminate root-owned processes by design.** `Sources/Shared/HelperTerminationPolicy.swift:17-21` requires `observed.owner != 0` and rejects `/System/Library`, `/usr/libexec`, `/usr/sbin`, `/sbin` paths (`TerminationService.swift:97-107`). After admin authorization the helper will only signal other non-root users' processes. That is a defensible policy, but Settings describes the helper as "Privileged helper" and the Processes page offers Force Quit on root processes with the rejection "This process belongs to another user." Decide: either document the policy in `docs/UI_ACCEPTANCE.md` and in the helper's Settings caption ("Lets you quit processes owned by other standard users; system processes stay protected"), or widen the policy deliberately with tests. Do not leave it implicit.

**M6 — XPC continuation wrappers are duplicated three times.** `OneReply` (`PrivilegedProcessActionController.swift:122-139`), `HandshakeCompletion` (`HelperHandshake.swift:24-37`), `SampleCompletion` (`HelperSamplingClient.swift:28-55`) are the same lock-guarded single-resume pattern. Extract `XPCSingleReply<T>` in `Sources/Integration/XPCReply.swift`; keep the 5 s / 25 s timeouts as parameters.

**M7 — `proc_listpids` cap silently truncates.** `SystemMonitorCollector.swift:401-410` caps at 16 384 PIDs and marks the snapshot incomplete; `AdvancedMetricsCollector.identities()` (`AdvancedMetricsCollector.swift:175-190`) returns an empty map on any size over 4 MiB, which marks all advanced per-process metrics "No process identities could be verified" without a specific reason. Both should surface a `detail` naming the cap.

**M8 — Helper `clientPID` from `connection.processIdentifier` is reusable.** `Sources/Helper/main.swift:27` stores the PID at connect time; `TerminationService.permits` compares `observed.pid != clientPID` to stop self-termination. The code-signing requirement on the connection already prevents an impostor, so this is a defense-in-depth note: prefer the audit token (`connection.value(forKey: "auditToken")` is private; the supported alternative is to compare the client's PID and start time captured at connect). Low effort; keep as is if time is short, but add a comment.

**M9 — `TerminationService.perform` accepts any 4 KiB JSON but does not bound `force` semantics by process group.** Not a bug; a note that `SIGKILL` on a parent does not touch children, which `UI_ACCEPTANCE.md` requires and the UI states. Add a test asserting `kill` is called exactly once with the requested PID.

**M10 — `SQLiteMonitoringHistoryStore.record` deletes retention rows inside the same transaction as the write, every sample.** `SQLiteMonitoringHistoryStore.swift:148-151`. Throttle (see H4). The interpolated `Int64` cutoff is safe but inconsistent with the bound statements elsewhere; bind it.

**M11 — Advanced metrics refresh runs unstructured.** `AdvancedMetricsCollector.swift:70-78` spawns `Task { await self.refresh() }` and sets `inFlight = false` only at the end of `refresh` (line 172). If `refresh` is cancelled or throws (it does not throw today) `inFlight` stays true forever. Wrap in `defer { inFlight = false }`.

**M12 — `FixtureMonitoringStore.start` uses a 10 s sleep for the refresh pulse.** `FixtureMonitoringStore.swift:56-63` makes `testSelectionSurvivesSnapshotRefresh` wait up to 16 s. Use 2 s.

### 3.4 Low

- **L1** `AppShellViewController.swift:118` `NSVisualEffectView.state = .followsWindowActiveState` is correct; `material = .sidebar` is correct; keep when moving to the outline view.
- **L2** `UIFormatting.swift:16` percent formatting uses `String(format:locale:)`; prefer `NumberFormatter` with `.percent` style and `maximumFractionDigits = 1` for locale-correct symbols.
- **L3** `UIFormatting.swift:18,39` `ByteCountFormatter` with `.memory` style for disk and network throughput shows binary-ish units; use `.decimal` for throughput (matches Activity Monitor) and `.memory` for RAM.
- **L4** `SettingsViewController.swift:85-93` observes `didBecomeActiveNotification` for the lifetime of the (cached) controller; fine, but move to `NativeSystemIntegrationAPI` so the status refresh does not depend on the Settings page having been visited.
- **L5** `config/base.xcconfig:7` `SWIFT_VERSION = 5.8`; add `SWIFT_STRICT_CONCURRENCY = complete` to Debug to surface actor-isolation issues before a Swift 6 move. The code already uses actors and `@MainActor` consistently, so this should be cheap.
- **L6** `scripts/validate.mjs` asserts `SWIFT_VERSION = 5.8` as a string match; if L5 changes the config, update the check.
- **L7** `.github/workflows/ci.yml:14` `runs-on: macos-26` and an Xcode 26/27 selector; confirm the label exists on GitHub-hosted runners for your plan before tagging, otherwise fall back to `macos-15` with Xcode 16.4 and verify the project builds there (deployment target is 14.0, nothing newer than macOS 14 APIs is used).
- **L8** `Sources/UI/SystemIntegrationAPI.swift` is `public` with `UnavailableSystemIntegrationAPI`; fine, but it lives under `UI/`. Move the protocol to `Core/` or `Integration/` for layering.
- **L9** `SQLiteMonitoringHistoryStore.swift:1077` `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` for `SQLITE_TRANSIENT` is the standard Swift idiom; add a one-line comment.
- **L10** `docs/UI_ACCEPTANCE.md` says "Closing the last window terminates the app"; after the toolbar/sidebar work keep `applicationShouldTerminateAfterLastWindowClosed` true (the UI test `testClosingLastWindowTerminatesTheApplication` depends on it).

### 3.5 Positives to keep

- The `MetricReading` / `MetricAvailability` model and the rule that unavailable is never zero. All UI work must keep honoring it.
- `ProcessIdentity` (PID + start time) everywhere, double revalidation before signaling (`LocalProcessActionController.swift:45-95`), and the helper's single-use authorization form (`TerminationService.swift:60-85`).
- `CounterDeltaTracker` with explicit baseline/reset/sleep-gap states and its tests.
- SQLite store: WAL, `BEGIN IMMEDIATE`, column-aware migration, UTC-day slicing with byte-conserving distribution, network interval dedup. Thorough tests (21).
- Helper hardening: code-signing requirement on the listener, fixed commands, bounded output, timeouts, `LC_ALL=C`, no inherited environment.
- Release tooling: secrets stripped from child environments, Sparkle archive signature verified against the configured public key with Node's crypto, draft release must target the verified commit, session-bound manifest.
- Accessibility identifiers are consistent and already documented by the UI tests.

### 3.6 Tests to add or change

| Test | Reason |
| --- | --- |
| `SystemMonitorCollectorTests.testCurrentProcessCPUPercentMatchesBusyLoop` | C1 regression |
| `NetworkInterfaceReaderTests.testTotalsExcludeLoopbackAndVirtualInterfaces` | H2 |
| `SystemMonitorCollectorTests.testMemoryPressureBaselineComesFromSysctl` (inject the sysctl) | H3 |
| `MonitoringStoreTests.testSnapshotPublishesBeforeHistoryWriteCompletes` and `testPollingPeriodDoesNotDriftWithSlowCollector` | H4, H5 |
| `WindowTests.testMainWindowOpensAtDefaultSizeAndAutosaves` (Core target, no UI runner) | H1 |
| `ProcessRowModelTests` (diff insert/remove/move, selection and expansion preserved, search semantics) | U11, U15 |
| `MetricCellPresentationTests` (value text, badge, tooltip for available / partial / unavailable) | U10 |
| Update `UIStateTests` to the outline view API | Phase B |
| `scripts/tests/changelog.test.mjs` already enforces format; add a check that 0.1.0 notes are non-placeholder | H7 |

---

## 4. Release hygiene checklist (do before tagging v0.1.0)

1. C1, H1, H2, H3 fixed and tested.
2. Phase A and Phase B of the UI plan at minimum; Phases C–E strongly recommended for a first impression.
3. Delete `TASK.md`, `TEST_RESULTS.md`; rewrite `docs/IMPLEMENTATION_STATUS.md`; real `CHANGELOG.md` entry; README status and screenshots.
4. Decide the UI-test gate policy (H6) and make `docs/RELEASING.md` match reality.
5. Decide the helper policy wording (M5).
6. Run: `npm run validate`, `npm run test:node`, Core XCTest (`-only-testing:MicrogravityCoreTests`), `npm run build:debug`, `npm run build:release-smoke`; manual pass of every page in light, dark, and System appearance at 1280×820 and at the minimum size; VoiceOver spot check of the Processes outline and the sidebar.
7. Delete this `plan.md`.
