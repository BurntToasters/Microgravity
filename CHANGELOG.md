# Microgravity changelog

## 0.1.0

First release of Microgravity, a native macOS 14+ process and system monitor.

### Monitoring

- Per-process CPU percentages are now correct. Process CPU times from the kernel are Mach ticks, not nanoseconds, and were read as nanoseconds; on Apple Silicon every process, group, user total, sort order, heat map and App History CPU value was about 42 times too low.
- Pre-release builds recorded App History CPU seconds with the wrong unit. If you tested a pre-release build, use Reset History (App History or Settings) to clear it before relying on per-app CPU history.
- System network totals exclude loopback, virtual, and tunnel interfaces so traffic is not counted twice. The per-interface list still shows every interface and marks which ones are included in totals.
- Memory pressure reads the current operating-system level at startup instead of waiting for the first pressure event.
- Process names and paths are cached per process identity, which reduces per-sample system calls.
- Sampling runs on a fixed schedule, so collection time no longer stretches the refresh interval.
- Snapshots are published before the history write completes, so a slow disk does not delay the interface. Retention cleanup runs once per UTC day instead of on every sample.
- Partial and unavailable measurements are labeled with a reason. Missing values are never shown as zero.

### Interface

- The main window opens at 1280 × 820 and remembers its size and position.
- Unified toolbar with page-specific actions; source-list sidebar grouped into Monitor and Inventory, with keyboard shortcuts (Command-1 through Command-8) and a sampling status footer.
- Standard View, Window, and Help menus, Settings (Command-comma), Check for Updates, and a Process menu.
- Processes is an outline view with app icons, heat-mapped cells, partial and unavailable badges with explanations, a selection bar, a context menu, and keyboard shortcuts.
- Performance has a metric rail with sparklines, a detail graph with grid lines, axis labels, gap markers, a time-window picker, per-core activity, a swap capacity bar, and a memory pressure timeline.
- App History shows one outline of applications and days.
- Startup and Services show status, item kind, discovery coverage, Reveal in Finder, and a shortcut to Login Items settings. They remain read-only.
- Users and Details are refreshed to match the new layout.
- Settings is a form for appearance, refresh interval, pause and resume, history reset, helper, login item, and updates.
- Confirmations for Force Quit and Reset History appear as sheets attached to the window.

### Process actions and privileges

- Quit and Force Quit act only on the selected process identity (PID and start time). The app revalidates that identity before sending a signal and reports when a PID was reused or the process exited.
- The optional privileged helper can quit processes owned by other standard users after administrator approval. It does not quit root-owned processes or processes in protected system locations (`/System/Library`, `/usr/libexec`, `/usr/sbin`, `/sbin`). Settings states this limit.

### Known limitations

- Helper authorization, notarized distribution, Sparkle update delivery, and VoiceOver behavior were not verified for this release. See the implementation status document.
