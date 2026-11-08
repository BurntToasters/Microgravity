# Core failure cases

These cases define what the collectors, store, history, and process controls must do when operating-system data is missing, stale, or unsafe. Missing data is represented as unavailable with its unit, timestamp, and reason; it is never silently replaced by zero.

| Area | Failure case | Required behavior / regression proof |
| --- | --- | --- |
| Metrics | First sample has no delta baseline | Return `warmingUp`; do not publish a fabricated zero rate. |
| Counters | A kernel counter decreases after reset | Rebase to the new count and timestamp; report `counterReset` for the affected interval. |
| Counters | Collection interval crosses a long sleep/suspend gap | Rebase and report `sleepGap`; do not smear the counter change over the suspended time. |
| Counters | Clock timestamps repeat or move backwards | Return `collectionFailed` for that sample and preserve a valid baseline. |
| Processes | A process exits between enumeration and metric lookup | Keep the rest of the snapshot; mark that process reading unavailable or omit the vanished process. |
| Processes | The OS reuses a PID for a different start time | Treat it as a new process identity and require fresh CPU/I/O baselines. |
| Processes | Parent exits or is not visible to this user | Preserve an unresolved parent identity where available and keep the group standalone; never infer ownership from a name. |
| Processes | Path/owner/CPU/footprint/I/O access is denied | Keep the process row and mark only affected readings/fields unavailable. |
| Processes | CPU units from `proc_taskinfo` | `pti_total_user + pti_total_system` are Mach absolute-time ticks, not nanoseconds. Convert ticks × numer / denom (`mach_timebase_info`, read once; 125/3 on Apple Silicon) to nanoseconds before the counter delta. Contract: process `cpuPercent` = Δns ÷ elapsed s ÷ 1e9 ÷ `capacityCores` × 100, so it is normalized to the whole machine and one saturated core on N cores reads 100/N. Regression: `testCurrentProcessCPUPercentMatchesBusyLoop` (±35%) and `testMachTicksConvertToNanosecondsWithTimebase`. |
| Processes | Name and executable path for a known process | Read once per `ProcessIdentity` and cached; the cache is evicted with the process counters when the identity leaves the snapshot. PID-reuse revalidation still runs every sample. |
| Processes | The `KERN_PROC_ALL` sysctl table (one read, all users including root) has more than 16 384 entries | Read at most 16 384 entries (`SystemMonitorCollector.maximumPIDCount`), return the processes read so far, mark the snapshot incomplete, and name the cap in the availability detail and discovery coverage (`processEnumerationCapDetail`). Never describe it as a generic omission. If the kernel rejects a buffer smaller than the table with ENOMEM instead of truncating, the read retries up to four attempts and then reports a sysctl failure (next row). Kernel truncation behavior is not verified on a live host. |
| Processes | `sysctl(KERN_PROC_ALL)` fails, or the table keeps changing across four attempts | Return no process rows and mark the process snapshot incomplete with `Process enumeration failed: sysctl KERN_PROC_ALL returned errno N.` or `Process enumeration could not read a stable process table.` Do not substitute zero or a partial table. |
| Processes | `proc_pid_rusage` fills the caller's `rusage_info_v4` buffer | Pass a real, correctly sized, zero-initialized struct through the C pointer type; a live current-PID test must find a nonzero footprint without crashing. |
| Memory pressure | The collector starts while pressure is already normal or elevated | Read `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical) on every sample as the baseline; dispatch events refine it between samples. Unavailable only when the sysctl fails and no level has been seen. Regression: `testMemoryPressureBaselineComesFromSysctl`. |
| Network | Loopback, tunnel, or virtual interfaces (`IFF_LOOPBACK`; `ifi_type` loopback/gif/stf/bridge; names `lo`, `utun`, `gif`, `stf`, `anpi`, `awdl`, `llw`, `bridge`, `ap`, `p2p`) | Keep them in the per-interface list with `includedInTotals = false`; exclude them from system receive/transmit totals so the same packets are not counted twice. Regression: `testTotalsExcludeLoopbackAndVirtualInterfaces`. |
| Advanced metrics | `nettop` output exceeds 4 MiB or does not parse | Per-process network metrics are unavailable with the sample's detail (`Network sample unavailable or invalid` when the helper reports no error); they are not reported as zero. The 4 MiB limit applies to command output (`AdvancedMetricsParser.maximumBytes`), not to the process list. |
| Advanced metrics | The `KERN_PROC_ALL` identity table cannot be read, or is cut at the cap | When no identity could be verified, per-process network metrics are unavailable with the enumeration detail. A table cut at the cap keeps the identities it read; processes beyond the cap get no per-process network reading. |
| Inventory | Launch-item/service enumeration is incomplete or unreadable | Return available entries plus `DiscoveryCoverage(complete: false, reasons: ...)`; never claim a complete inventory. |
| Inventory | Static launch-item directories contain many plists and collection runs frequently | Cache the filesystem inventory for a bounded interval while refreshing running state from the current process set. |
| Inventory | A startup/service entry has no resolved owner, path, or runtime state | Leave that field absent/unknown and preserve the entry. |
| Discovery | Login/session query fails | Return incomplete coverage and any sessions already discovered. |
| History | SQLite file is absent, schema is old, or migration fails | Create/migrate transactionally; version 2 adds per-application totals without dropping version 1 daily totals; on error expose history unavailable and do not erase the prior database. |
| History | App is closed or no sample is collected | Write nothing. System and application history contain only samples accumulated while this process is running. |
| App history | Processes share a real application bundle or parent group | Aggregate once per stable bundle ID + app path, or executable/parent identity; prevent overlapping parent/child membership from double-counting. |
| App history | No public per-process network source is integrated | Preserve network totals as unavailable. Never allocate system traffic to applications or guess destinations. |
| History | Retention crosses 30 days | Delete only expired daily totals; preserve recent totals and explicit gaps/reset counts. |
| History | User clears history while storage is unavailable | Return the clear failure to the caller; do not report success or discard in-memory evidence. |
| History | Database write is interrupted | Keep SQLite transaction atomic and record gaps on the next successful write where possible. Store no command-line arguments or destination values. |
| History | The monitor is relaunched between samples | Persist the last committed collection boundary, mark the session gap, and leave usage NULL instead of integrating across the relaunch. |
| History | An application aggregate is prepared but its transaction fails | Keep the previous application baseline until COMMIT succeeds; the next successful sample must measure from the last committed boundary. |
| History | The user clears history while a record is in flight | Serialize reset after the active write and invalidate stale publications so no pre-reset record can restore deleted rows. |
| History | Monitoring is paused and resumed | Mark the first resumed history interval as a gap and do not integrate its rates across the pause. |
| Store | Collector is slow, paused, or interval changes mid-cycle | Keep one bounded poll loop, avoid overlapping collections, stop publishing while paused, and apply the new interval. |
| Store | UI listener is attached/detached during collection | Deliver callbacks on the main actor and retain at most 720 graph samples. |
| Store | CoreMetrics callback supplies a new GPU/energy value | Preserve metric unit, timestamp, and unavailable reason in snapshots and graph samples; never relabel energy as power. |
| Actions | PID is gone, reused, root-owned, another user's, PID 1, the caller itself, or protected | Revalidate PID + start time + owner immediately before signaling; reject with an explicit outcome and send no signal. |
| Actions | Signal fails or privileged helper is unavailable | Return the failure; never escalate through a hidden or guessed helper. |

## Regression tests

`Tests/CoreTests/` covers unavailable-vs-zero readings, identity-safe counter baselines, sleep/reset handling, schema migration/retention/system and per-app totals/gaps, duplicate-membership prevention, store pause/interval/main-actor/bounded-buffer behavior, and process-action revalidation/rejection. Native collection remains dependent on live macOS APIs; tests use deterministic injected providers for failure branches.
