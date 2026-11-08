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

## Verification status

Live helper installation, authorization, process attribution, and the `powermetrics` key names and units on Intel and Apple silicon still require signed, target-host testing. The privileged commands were not run as root for this implementation.
