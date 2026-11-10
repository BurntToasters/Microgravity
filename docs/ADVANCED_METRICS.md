# Advanced metrics collection

Advanced sampling is optional and runs through the authenticated helper. The app requests fixed `nettop` and `powermetrics` commands, never arbitrary arguments. Sampling is asynchronous and has at most one refresh in flight. Each refresh checks helper registration and signing once, then requests one `nettop` and one `powermetrics` sample. Refreshes run no more often than every five seconds while the helper responds, and no more often than every 60 seconds after a refresh reports `helperUnavailable`; the first successful sample restores the five-second cadence. When the app becomes active (`NSApplication.didBecomeActiveNotification`, observed in `AppComposition`), the next sample requests a refresh immediately even inside that 60-second backoff, so approving the helper in System Settings takes effect on return. This request has no effect while the helper is responding. The helper also enforces its own five-second minimum spacing per sample kind. Cached readings keep the helper capture time; samples older than 30 seconds are unavailable. Helper absence, denial, command failure, invalid output and stale data are not zeros.

`nettop -n -P -x -L 1 -J bytes_in,bytes_out` requests raw per-process CSV totals. `man nettop` documents `-P`, `-x`, `-L`, and column selection. The observed raw layout has an unlabeled first process column followed by `bytes_in` and `bytes_out`, with an optional trailing empty CSV field; the parser also accepts labeled `interface` layouts with other columns such as time or state. Input is limited to 4 MiB. The parser handles quoted CSV names and rejects malformed schemas, malformed quoting, and ambiguous duplicate PIDs. Process identities (PID plus start time) are read before and after the command from the `KERN_PROC_ALL` sysctl table (`SystemMonitorCollector.processIdentityLookup`), which covers processes of all users, including root. Earlier builds read identities with `proc_pidinfo(PROC_PIDTBSDINFO)`, which missed other users' processes. A missing or changed identity is discarded. If the table cannot be read, per-process network readings are unavailable with the enumeration detail. A table cut at the 16,384-process cap keeps the identities it read; processes beyond the cap get no per-process network reading. Rates use monotonic counter differences, with warm-up, counter reset, and long gaps represented as unavailable. No socket destinations or command output are persisted.

## Power and GPU (powermetrics)

The app runs:

```
powermetrics -f plist -i 1000 -n 1 -s cpu_power,gpu_power
```

This emits NUL-separated plist records according to local `powermetrics --help`. The parser reads the last record. Per-process GPU time is not requested and not collected: `tasks` sampling and `--show-process-gpu` were removed, and the `processGPUTime` capability always reports unsupported with the detail "Per-process GPU time is not collected."

**GPU activity.** On the observed plist shape, `gpu.idle_ratio` is a fraction; GPU active percentage is `100 * (1 - idle_ratio)`. The parser requires a finite numeric value in [0,1]. This key is an observed schema, not a public compatibility guarantee; for an example consumer see [thor's parser](https://github.com/okuvshynov/thor/commit/bcc34324af629813b38d8958b3e2eb828b7f0eb3).

**Energy (system power).** Power keys are in milliwatts and are converted to watts. The parser uses:

1. `processor.combined_power` when that key is present. A present but invalid value yields unavailable; the parser does not fall back to components.
2. Otherwise, `processor.cpu_power`, `processor.gpu_power` and `processor.ane_power`, all three required. A partial set is unavailable.

Values must be finite, non-negative numbers; booleans, strings, and negative values are rejected. The earlier `*_mw` field names were hypothetical and are no longer read. Output that carries none of these keys, which is what the parser expects on Intel (unverified), reports energy as unsupported.

**These key names have not been verified against Apple output.** They come from public open-source consumers of `powermetrics` plist output, not from a capture made by this project. Confirm them against a captured `sudo powermetrics -f plist -n 1 -s cpu_power,gpu_power` on Apple silicon and on Intel before relying on energy readings. Synthetic tests encode these shapes and do not claim a hardware capture.

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

**Shipped builds.** The shipped 0.2.0 app and helper satisfy the Release requirement, checked with `codesign --verify -R`.

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

**Sampling child processes.** The helper starts `nettop` and `powermetrics` with `posix_spawn` and reaps them itself. A SIGKILL on timeout, output overflow, or disconnect reaches a child only while the child is unreaped. An exited but unreaped child still holds its PID, so the signal cannot reach a reused PID. Each child runs with:

- environment exactly `PATH=/usr/bin:/bin` and `LC_ALL=C`
- working directory `/`
- stdin and stderr on `/dev/null`
- no inherited descriptors other than its stdout pipe to the helper

**Sample access.** The `sample` request needs no administrator authorization. Any local user who runs the signed app, including a standard account, receives per-process network byte totals for processes of all users, from `nettop`, and system power and GPU readings, from `powermetrics`. This is normal for a system monitor.

## Verification status

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
