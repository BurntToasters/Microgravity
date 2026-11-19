# Advanced metrics collection

Microgravity 0.3.0 uses a hybrid telemetry pipeline that pairs unprivileged 1-second native hardware/network readers inside `Microgravity.app` with an upgraded v2 privileged helper (`MicrogravityHelper`) for root/other-user process metrics and Intel/fallback sampling.

## Native unprivileged collectors (1s tick)

- **System power and battery telemetry (`AppleSMCReader` + `PowerTelemetryCollector`):** Safely opens read-only `AppleSMC` keys (`PSTR` System Total Power, `PDTR` DC-In, `PB0R`/`PPBR` Battery Power) over one connection that stays open, with key info cached. Any failed call closes the connection and clears the cache. It reads `AppleSmartBattery` (`PowerTelemetryData`, charge, voltage/amperage, adapter rating) plus `IOPSCopyPowerSourcesInfo` and `ProcessInfo thermalState`. Reconciles true System Power (W) on **both AC and Battery**, falling back to labeled Component Power only when platform total sensors are unavailable (such as on virtual machines).
- **Apple Silicon GPU % and SoC component power (`IOReportCollector`):** Dynamically loads `/usr/lib/libIOReport.dylib` via `dlopen`/`dlsym` (`#if arch(arm64)`, zero link-time dependency, clean no-op fallback on `x86_64` and virtualized Macs). It subscribes only to channels that feed a reading: the `"Energy Model"` CPU Energy, GPU Energy, `ANE*` and `DRAM*` channels, and the `"GPU Stats"` `GPU Performance States` channel for utilization %. On an M5 Pro this is about five channels instead of roughly 500. Per-cluster CPU channels (`ECPU`, `PCPU`, `MCPU`) are used only when a sample has no CPU Energy value. The M5 Pro refreshes its mJ energy counters only about every 2.1 s, so each component's `EnergyRateTracker` holds its last rate between refreshes and divides each refresh by the measured refresh period. CPU power therefore stays steady instead of alternating between 0 W and twice the value. DRAM power is reported from the `DRAM0` channel.
- **Rootless streaming `nettop` (`NettopStreamService`, app only):** The app runs `/usr/bin/nettop -n -P -x -t external -d -L 0 -s 1 -J bytes_in,bytes_out` as the current user, under `/usr/bin/script -q /dev/null`, so nettop has a pseudo-terminal and its continuous `-L 0` output is not block-buffered. The app reads the output through a plain pipe. If the app exits, for any reason including a crash, force quit or `kill -9`, the pipe closes. `script` gets SIGPIPE on its next write and exits, and nettop gets SIGHUP. Child processes start with SIGPIPE at its default action, so a parent that ignores SIGPIPE cannot keep `script` alive. If `/usr/bin/script` is missing, nettop runs on its own pseudo-terminal. A failed spawn is retried after 5 s. The stream stops after 15 seconds without a client poll, and on app termination. Frame 0's cumulative totals are skipped; frames `>= 1` emit 1-second external deltas parsed from the right so commas inside process names never misalign columns. The helper does not run nettop, so this stream is the only source of per-process network and it works without the helper.
- **Hardware spec metadata (`HardwareSpecReader`):** Cached read-once machine model, CPU brand, GPU model and core count (read from the IORegistry `IOAccelerator` first, with Metal as fallback), physical RAM summary, and boot disk model and capacity. The active primary interface detail is cached for 30 s per interface.

## Refresh scheduling

`NativeAdvancedMetricsCollector` merges the two sources on each read:

- **Network** is refreshed synchronously from the app's nettop stream, at most every 0.9 s. It never waits for the helper.
- **Helper** (GPU, energy and per-process system counters) is refreshed in a background task, with one refresh in flight. It runs every 0.9 s while healthy, 5 s after a failed process-metrics call, and 60 s while the helper is unavailable. After the app becomes active, a helper that was unavailable is checked at once.
- **powermetrics** is sampled at most every 5 s, as part of a helper refresh, and only when native power readings are not in use (see below).
- **Warming up.** On Apple Silicon, GPU and energy show "warming up" rather than "requires the helper" until IOReport has a reading.
- A reading older than 30 s is not shown.

## Privileged helper sampling (Protocol v2)

Helper sampling is optional and runs through the authenticated XPC helper (`helperProtocolVersion = 2`) using a reused cached `NSXPCConnection` that invalidates cleanly on disconnect, timeout, or on-disk Sparkle update replacement. The helper serves two sample kinds, `processMetrics` and `powermetrics`. It does not run `nettop`; per-process network comes from the app's own stream (see above).

- **Privileged process metrics (`.processMetrics`):** Reads `proc_pidinfo(PROC_PIDTASKINFO)`, `proc_pid_rusage(RUSAGE_INFO_V4)`, and `proc_pidpath` as root for non-caller UIDs (rate-limited at 0.5s, capped at 4,096 PIDs, with `KERN_PROC_PID` start-time revalidation after reads) so root/system processes (`WindowServer`, `launchd`, `mds_stores`) report real CPU, memory, disk, threads, and paths without `EPERM` `?` markers. Each capture carries the helper's capture time. The app takes CPU and disk rates over that time, so a capture reused between refreshes returns the previous reading, and captures older than 5 s are dropped.
- **`powermetrics` fallback (`.powermetrics`):** Still runs at a 5-second cadence (`powermetrics -f plist -i 1000 -n 1 -s cpu_power,gpu_power`) only when native `IOReport`/power sensors are unavailable: on Intel Macs, or on Apple Silicon without IOReport hardware channels. It parses Intel `processor.package_watts` as well as Apple Silicon keys.

When the app's nettop stream is healthy, verified live processes absent from a delta frame report **`0 B/s`** with the frame's `idleZeroInterval` rather than `.notCollected`. On transient `"rateLimited"` / `"busy"` helper errors, fresh (`<= 30s`) cached readings are preserved instead of flickering to unavailable. Helper absence (`helperUnavailable`) is checked on a 60-second backoff and retried immediately when `NSApplication.didBecomeActiveNotification` fires after System Settings approval. No socket destinations or raw command outputs are persisted.

Process identities (PID plus start time) are read before and after sampling from `KERN_PROC_ALL` (`SystemMonitorCollector.processIdentityLookup`), covering all users up to 16,384 entries. Routine one-tick subprocess warm-ups (`warmingUp`), exits (`processExited`), identity changes, and sub-50ms frame timestamp jitter no longer mark parent application groups partial (`!`) or record false App History gaps.

## Power and GPU (`powermetrics` fallback)

When helper `powermetrics` runs:

```
powermetrics -f plist -i 1000 -n 1 -s cpu_power,gpu_power
```

Per-process GPU time is not requested or collected (`processGPUTime` remains `.unsupported`). GPU activity computes `100 * (1 - gpu.idle_ratio)` when in `[0, 1]`. Energy uses `processor.combined_power` (mW -> W) when that key is present; if its value is invalid, no energy reading is produced. Without that key, energy is `processor.cpu_power + gpu_power + ane_power` (mW -> W) when all three are present, else Intel `processor.package_watts` (W). Individual `cpu_power`, `gpu_power`, `ane_power`, and `dram_power` keys are also surfaced when present. Values must be finite and non-negative.

## Helper trust and authorization

The app and the helper each check the other's code signature before they exchange requests. Each check uses a code requirement that names the peer's identifier and the team ID from the checking process's own signature. Release builds use a strict form. Debug builds use a looser form so that development-signed builds can connect.

**Release requirement.** A Release build accepts a peer only if the peer satisfies this requirement, with `TEAMID` set to the 10-character Apple Team ID. The app checks the helper with `identifier "run.rosie.microgravity.helper"`. The helper checks the app with `identifier "run.rosie.microgravity"`:

```
anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "TEAMID" and identifier "run.rosie.microgravity.helper" and !(entitlement["com.apple.security.get-task-allow"] exists) and !(entitlement["com.apple.security.cs.disable-library-validation"] exists) and !(entitlement["com.apple.security.cs.allow-dyld-environment-variables"] exists)
```

The requirement needs the Developer ID intermediate (OID 1.2.840.113635.100.6.2.6) and the Developer ID leaf (OID 1.2.840.113635.100.6.1.13). It rejects a peer that carries `com.apple.security.get-task-allow`, `com.apple.security.cs.disable-library-validation`, or `com.apple.security.cs.allow-dyld-environment-variables`.

**Debug requirement.** Debug builds, which set the `DEBUG` compilation condition in both targets, accept any Apple-anchored peer with the fixed identifier and the same team ID:

```
anchor apple generic and identifier "run.rosie.microgravity.helper" and certificate leaf[subject.OU] = "TEAMID"
```

**Shipped builds.** Shipped release builds satisfy the Release requirement, checked with `codesign --verify -R`.

**Helper lifetime.** The helper computes its requirement once, at startup, not on each connection. A Sparkle update can replace the helper on disk while an older helper is still running, and that process keeps its startup requirement until it exits. The helper exits in two cases, and launchd then starts the current on-disk binary on the next connection:

- **Update.** At startup the helper records its executable's device, inode, size and modification time. It compares them every 5 seconds and on each new connection. Once they differ, it refuses new connections and exits as soon as no verified client connection remains. It does not wait for consumed authorizations, because every termination prompts again.
- **Idle.** 30 seconds after the last verified client connection closes. The helper does not exit for idleness while a consumed termination authorization is still within its 10-minute lifetime, because that record is held in memory.

**Verified connections.** The code-signing requirement is enforced when a connection sends its first message, not when it opens. A connection counts toward the helper's lifetime only after its first message is accepted. A connection that sends no accepted message within 10 seconds is closed, so an unsigned local process cannot keep the helper running.

**Termination authorization.** The app does not obtain an administrator right itself. For each quit, it sends the helper the target's PID and start time, together with an empty `AuthorizationRef` external form. The helper then:

1. Validates the target: PID, start time, owner, and protection under the [process action policy](UI_ACCEPTANCE.md#process-action-policy-privileged-helper). It rejects root-owned targets, PID 1, its own process, and the client.
2. Records the form as used. A form authorizes one request only.
3. Requests the right `run.rosie.microgravity.terminate` with UI allowed. The helper writes the dialog text from its own lookup of the process name and PID, so the app cannot change it.
4. After approval, looks the target up again and signals only if the identity is unchanged.
5. Sends no signal, and returns `approvalExpired`, if the approval arrives more than 100 seconds after the request or after the client connection closed. The app stops waiting after 120 seconds, so a late approval can never quit a process the app already reported as not quit.

The helper registers that right in the authorization database on first use, with class `user`, group `admin`, `authenticate-user` true, `allow-root` false, `shared` false, and `timeout` 0. If a rule with that name already exists but lacks these settings (`allow-root` true, `shared` not false, `timeout` not 0, another group or class), the helper rewrites it. If registration fails, termination fails. Remove Helper does not delete the right from the authorization database. Removing it needs administrator authorization (`sudo security authorizationdb remove run.rosie.microgravity.terminate`). A leftover right grants nothing on its own. An approval therefore applies only to the process the helper signals. The app cannot reuse one approval for another process, and it cannot change the dialog text. The app waits up to 120 seconds for the helper's reply.

**Residual risk.** Termination of another user's process is by PID, after the double identity check. A PID could in theory be reused between the final check and `kill`. The window is very small, and macOS offers no race-free process handle for `kill`. This risk is accepted.

**Audit log.** The helper writes to the unified log under subsystem `run.rosie.microgravity.helper`, in three categories:

- `connection`: accepted, invalidated, and rejected connections, with client PID and UID; idle exit.
- `terminate`: each termination request, with client PID and UID, target PID, force flag, and result.
- `sample`: each sample request, with client PID, sample kind, and result.

Authorization bytes are never logged. To view the entries:

```
log stream --predicate 'subsystem == "run.rosie.microgravity.helper"' --info
```

**Sampling child processes.** The helper starts `powermetrics` with `posix_spawn` and reaps it itself. A SIGKILL on timeout, output overflow, or disconnect reaches a child only while the child is unreaped. An exited but unreaped child still holds its PID, so the signal cannot reach a reused PID. Each child runs with:

- environment exactly `PATH=/usr/bin:/bin` and `LC_ALL=C`
- working directory `/`
- stdin and stderr on `/dev/null`
- no inherited descriptors other than its stdout pipe to the helper

**Sample access.** The `sample` request needs no administrator authorization. Any local user who runs the signed app, including a standard account, receives per-process CPU, memory and disk counters for processes owned by other users (`processMetrics`), and system power and GPU readings from `powermetrics`. Per-process network is not requested from the helper: the app reads it from its own nettop stream, as its own user. This is normal for a system monitor.

## Verification status

Status of the nettop, helper and power changes in this 0.3.0 work, on an Apple M5 Pro (`Mac17,9`, macOS 27.2.1), a physical Mac:

- Done: the full `MicrogravityCoreTests` suite passed after the first batch of these changes. A final run after all changes is pending.
- Pending: orphan check (`kill -9` the app; `script` and nettop must exit); no nettop process running as root; steady CPU power; DRAM power shown; helper CPU % steady at a 0.5 s refresh; network without the helper; UI parity.

Live helper installation, authorization, process attribution, and the `powermetrics` key names and units on Intel and Apple silicon still require signed, target-host testing. The privileged commands were not run as root for this implementation. The helper trust, termination, and logging behavior above has not been run on a Developer ID-signed build on a real host either.

Run this checklist on a Developer ID-signed Release build on a real host:

1. Strict requirement. Substitute the team ID for `TEAMID` in the Release requirement above, and use `identifier "run.rosie.microgravity"` for the app and `identifier "run.rosie.microgravity.helper"` for the helper. Both commands must succeed:
   ```
   codesign --verify -R='<app requirement>' /path/to/Microgravity.app
   codesign --verify -R='<helper requirement>' /path/to/Microgravity.app/Contents/Helpers/MicrogravityHelper
   ```
2. A Debug build signed with an Apple Development certificate cannot connect to a Release helper.
3. Quit a process owned by another user. The dialog names the process and PID. Cancel shows "Administrator authorization was not granted." and sends no signal. Approval sends exactly one signal.
4. A fresh `AuthorizationRef` with no rights is denied when the helper checks it without UI. The unit tests cover this without UI. Confirm the denial on the host.
5. `security authorizationdb read run.rosie.microgravity.terminate` shows `allow-root` false, `shared` false, and `timeout` 0. The helper registers the right on first use, so run this after the first termination request.
6. The unified log shows the `connection`, `terminate`, and `sample` entries, and an idle exit entry, as described in the audit log section.
7. The helper exits about 30 seconds after the app quits when no termination authorization is within its 10-minute lifetime. After a termination, it stays running until that lifetime ends. Check with `launchctl print system/run.rosie.microgravity.helper`. The next request starts it again.
8. After a Sparkle update, the helper exits within about 5 seconds of the bundle replacement, or as soon as its last in-flight request ends, while the updated app keeps running. Record the helper PID before the update. After the update, the PID has changed, the log shows `stale exit`, and the new process runs `Contents/Helpers/MicrogravityHelper` from the updated bundle.
9. A process that opens a connection to `run.rosie.microgravity.helper` and sends nothing is closed after about 10 seconds and does not prevent idle exit.
10. With the approval dialog open, wait more than 100 seconds, then approve. No signal is sent, and the log shows `approvalExpired`.
