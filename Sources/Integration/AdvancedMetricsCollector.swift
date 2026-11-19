import Darwin
import Foundation

/// The app's rootless nettop stream, behind a seam so the collector can run without a child process.
protocol NettopStreamProviding: Sendable {
    func latestSnapshot(since sequence: UInt64?, now: Date) -> NettopStreamSnapshot
}

extension NettopStreamService: NettopStreamProviding {}

protocol AdvancedSamplingClient: Sendable {
    /// Runs once per refresh, before any sample. Returning false ends the refresh without sampling.
    func prepareRefresh() async -> Bool
    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse
}

extension AdvancedSamplingClient {
    func prepareRefresh() async -> Bool { true }
}

extension HelperSamplingClient: AdvancedSamplingClient {}

/// Process identities for the current process list, or the reason they could not be enumerated.
struct ProcessIdentityLookup: Sendable {
    var identities: [Int32: ProcessIdentity]
    var failureDetail: String?

    init(identities: [Int32: ProcessIdentity], failureDetail: String? = nil) {
        self.identities = identities
        self.failureDetail = failureDetail
    }
}

/// Merges two sources on read. Network comes from the app's own rootless nettop stream and is refreshed
/// synchronously, at most every `fastRefreshInterval`, so a hung helper never delays it. System GPU/energy and
/// per-process counters come from the privileged helper, refreshed in a background task with one refresh in
/// flight and backoff after failures.
actor NativeAdvancedMetricsCollector: AdvancedMetricsCollecting {
    /// Maximum age of a reading, measured from its capture time to read time.
    static let maximumSampleAge: TimeInterval = 30
    /// Helper spacing after a failed helper call (other than "unavailable") and while powermetrics is sampled.
    static let refreshInterval: TimeInterval = 5
    /// Minimum spacing between network refreshes, and between helper refreshes while the helper is healthy.
    static let fastRefreshInterval: TimeInterval = 0.9
    /// Minimum spacing between helper availability rechecks when the helper is absent.
    static let helperUnavailableRetryInterval: TimeInterval = 60
    private static let maximumClockSkew: TimeInterval = 1
    /// Maximum age of helper per-process counters, from the helper's capture time to read time.
    static let maximumProcessCounterAge: TimeInterval = 5
    private static let networkKinds: [MetricKind] = [.processNetwork, .processNetworkReceive, .processNetworkTransmit]
    private static let helperKinds: [MetricKind] = [.gpu, .energy]
    private static let warmingUpAvailability = MetricAvailability(available: false, reason: .warmingUp)
    private static let networkNotConfiguredAvailability = MetricAvailability(
        available: false, reason: .notCollected, detail: "No local network stream is configured.")
    /// No verified powermetrics output provides per-process GPU time, so it is never collected.
    static let processGPUTimeAvailability = MetricAvailability(available: false, reason: .unsupported,
                                                               detail: "Per-process GPU time is not collected.")

    /// Network part: per-process rates and the three network capabilities, rebuilt on every network refresh.
    private struct NetworkState {
        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var capabilities: [MetricKind: MetricAvailability]
        var idleZeroInterval: DateInterval?
    }

    /// Helper part: system GPU/energy readings, their capabilities, and per-process system counters.
    private struct HelperState {
        var system: [MetricKind: MetricReading] = [:]
        var capabilities: [MetricKind: MetricAvailability]
        var perProcessSystemMetrics: [ProcessIdentity: CollectedProcessSystemMetrics] = [:]
    }

    private let client: any AdvancedSamplingClient
    private let localNettopStream: (any NettopStreamProviding)?
    private let shouldSamplePowermetrics: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let processIdentities: @Sendable () -> ProcessIdentityLookup
    private var network: NetworkState
    private var helper = HelperState(capabilities: [.gpu: NativeAdvancedMetricsCollector.warmingUpAvailability,
                                                    .energy: NativeAdvancedMetricsCollector.warmingUpAvailability])
    private var lastNetworkRefresh: Date?
    private var lastHelperCompleted: Date?
    private var lastPowermetricsSampleAt: Date?
    private var lastLocalNettopSequence: UInt64?
    private var lastResultWasHelperUnavailable = false
    /// Consecutive helper refreshes whose process-metrics call failed for a reason other than "unavailable".
    private var helperFailureCount = 0
    /// Set by retryHelperSoon(); honored only while the last result was helper-unavailable.
    private var helperRetryRequested = false
    private var inFlight = false
    private var refreshRequestCount = 0
    private var refreshCompletionCount = 0

    init(client: any AdvancedSamplingClient = HelperSamplingClient(),
         localNettopStream: (any NettopStreamProviding)? = nil,
         shouldSamplePowermetrics: @escaping @Sendable () -> Bool = { true },
         now: @escaping @Sendable () -> Date = { Date() },
         processIdentities: (@Sendable () -> [Int32: ProcessIdentity])? = nil,
         processIdentityLookup: (@Sendable () -> ProcessIdentityLookup)? = nil) {
        self.client = client
        self.localNettopStream = localNettopStream
        self.shouldSamplePowermetrics = shouldSamplePowermetrics
        self.now = now
        let networkAvailability = localNettopStream == nil
            ? NativeAdvancedMetricsCollector.networkNotConfiguredAvailability
            : NativeAdvancedMetricsCollector.warmingUpAvailability
        self.network = NetworkState(capabilities: [.processNetwork: networkAvailability,
                                                   .processNetworkReceive: networkAvailability,
                                                   .processNetworkTransmit: networkAvailability])
        let lookup: @Sendable () -> ProcessIdentityLookup
        if let processIdentityLookup {
            lookup = processIdentityLookup
        } else if let processIdentities {
            lookup = { ProcessIdentityLookup(identities: processIdentities()) }
        } else {
            lookup = { SystemMonitorCollector.processIdentityLookup() }
        }
        self.processIdentities = lookup
    }

    /// Asks for a helper refresh on the next collect, skipping the helper-unavailable backoff. Used when the app
    /// becomes active, since the user may have just approved the helper in System Settings.
    /// No effect on a healthy helper.
    func retryHelperSoon() {
        guard lastResultWasHelperUnavailable else { return }
        helperRetryRequested = true
    }

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        let currentTime = now()
        refreshNetworkIfDue(at: currentTime)
        startHelperRefreshIfDue(at: currentTime)
        return freshReadings(in: mergedSnapshot(), at: currentTime)
    }

    func refreshRequestCountForTesting() -> Int { refreshRequestCount }
    func refreshCompletionCountForTesting() -> Int { refreshCompletionCount }

    // MARK: Network (synchronous)

    private func refreshNetworkIfDue(at currentTime: Date) {
        guard let stream = localNettopStream else { return }
        if let last = lastNetworkRefresh, currentTime >= last,
           currentTime.timeIntervalSince(last) < Self.fastRefreshInterval {
            return
        }
        lastNetworkRefresh = currentTime

        let beforeLookup = processIdentities()
        let streamSnapshot = stream.latestSnapshot(since: lastLocalNettopSequence, now: currentTime)
        let afterLookup = processIdentities()

        var result = NetworkState(capabilities: [:])
        applyLocalNettopSnapshot(streamSnapshot,
                                 before: beforeLookup.identities,
                                 after: afterLookup.identities,
                                 identityFailure: beforeLookup.failureDetail ?? afterLookup.failureDetail,
                                 perProcess: &result.perProcess,
                                 capabilities: &result.capabilities,
                                 idleZeroInterval: &result.idleZeroInterval)
        network = result
    }

    // MARK: Helper (asynchronous)

    private func startHelperRefreshIfDue(at currentTime: Date) {
        guard !inFlight, helperRefreshDue(at: currentTime) else { return }
        inFlight = true
        helperRetryRequested = false
        refreshRequestCount += 1
        Task { await self.refreshHelper() }
    }

    private func helperRefreshDue(at currentTime: Date) -> Bool {
        if helperRetryRequested { return true }
        guard let completed = lastHelperCompleted else { return true }
        if currentTime < completed { return true }
        return currentTime.timeIntervalSince(completed) >= helperRefreshInterval
    }

    private var helperRefreshInterval: TimeInterval {
        if lastResultWasHelperUnavailable { return Self.helperUnavailableRetryInterval }
        if helperFailureCount > 0 { return Self.refreshInterval }
        return Self.fastRefreshInterval
    }

    private func refreshHelper() async {
        defer { inFlight = false; refreshCompletionCount += 1 }
        guard await client.prepareRefresh() else {
            helper = HelperState(capabilities: helperUnavailableCapabilities())
            finishHelperRefresh(unavailable: true, processFailed: false)
            return
        }

        let processResponse = await client.sample(.processMetrics)
        let identities = processIdentities().identities
        if processResponse.error == HelperSamplingClient.unavailableError {
            helper = HelperState(capabilities: helperUnavailableCapabilities())
            finishHelperRefresh(unavailable: true, processFailed: false)
            return
        }
        // Committed before the powermetrics call so readers see fresh per-process counters while it runs.
        helper.perProcessSystemMetrics = Self.processSystemMetrics(processResponse, identities: identities,
                                                                   previous: helper.perProcessSystemMetrics)

        var powermetricsUnavailable = false
        let requestTime = now()
        if !shouldSamplePowermetrics() {
            // IOReport measures GPU and energy natively; the helper does not sample powermetrics.
            helper.system = [:]
            helper.capabilities = Self.warmingUpHelperCapabilities
        } else if powermetricsDue(at: requestTime) {
            lastPowermetricsSampleAt = requestTime
            let power = await client.sample(.powermetrics)
            let responseTime = now()
            let existingFresh = freshReadings(in: AdvancedMetricsSnapshot(system: helper.system,
                                                                          capabilities: helper.capabilities),
                                              at: responseTime)
            var system = existingFresh.system
            var capabilities = helper.capabilities
            applyPowermetricsResponse(power, at: responseTime, existingFresh: existingFresh,
                                      system: &system, capabilities: &capabilities)
            helper.system = system
            helper.capabilities = capabilities
            powermetricsUnavailable = power.error == HelperSamplingClient.unavailableError
        }

        finishHelperRefresh(unavailable: powermetricsUnavailable,
                            processFailed: Self.isFailure(processResponse.error))
    }

    private func powermetricsDue(at currentTime: Date) -> Bool {
        guard let last = lastPowermetricsSampleAt else { return true }
        return currentTime.timeIntervalSince(last) >= Self.refreshInterval || currentTime < last
    }

    private func finishHelperRefresh(unavailable: Bool, processFailed: Bool) {
        lastResultWasHelperUnavailable = unavailable
        helperFailureCount = (processFailed && !unavailable) ? helperFailureCount + 1 : 0
        lastHelperCompleted = now()
        if !unavailable { helperRetryRequested = false }
    }

    /// GPU and energy capabilities when the helper cannot sample them. Native measurement says "warming up", not
    /// "requires the helper", because IOReport may simply have no reading yet.
    private func helperUnavailableCapabilities() -> [MetricKind: MetricAvailability] {
        let availability = shouldSamplePowermetrics()
            ? MetricAvailability(available: false, reason: .notCollected, detail: Self.helperRequiredDetail)
            : Self.warmingUpAvailability
        return [.gpu: availability, .energy: availability]
    }

    private static let warmingUpHelperCapabilities: [MetricKind: MetricAvailability] = [
        .gpu: NativeAdvancedMetricsCollector.warmingUpAvailability,
        .energy: NativeAdvancedMetricsCollector.warmingUpAvailability,
    ]

    /// Both parts merged, before freshness filtering.
    private func mergedSnapshot() -> AdvancedMetricsSnapshot {
        var capabilities = network.capabilities.merging(helper.capabilities) { current, _ in current }
        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        return AdvancedMetricsSnapshot(system: helper.system,
                                       perProcess: network.perProcess,
                                       capabilities: capabilities,
                                       idleZeroInterval: network.idleZeroInterval,
                                       perProcessSystemMetrics: helper.perProcessSystemMetrics)
    }

    /// Drops readings whose own capture time is older than `maximumSampleAge` (or implausibly in the future)
    /// and marks their kinds unavailable, so a cached refresh cannot outlive its samples.
    private func freshReadings(in snapshot: AdvancedMetricsSnapshot, at currentTime: Date) -> AdvancedMetricsSnapshot {
        func isRecent(_ timestamp: Date, maximumAge: TimeInterval) -> Bool {
            let age = currentTime.timeIntervalSince(timestamp)
            return age <= maximumAge && age >= -Self.maximumClockSkew
        }
        func isFresh(_ reading: MetricReading) -> Bool {
            isRecent(reading.timestamp, maximumAge: Self.maximumSampleAge)
        }
        var system = snapshot.system
        var perProcess = snapshot.perProcess
        var capabilities = snapshot.capabilities
        var staleKinds = Set<MetricKind>()
        for (kind, reading) in snapshot.system where !isFresh(reading) {
            system[kind] = nil
            staleKinds.insert(kind)
        }
        for (identity, readings) in snapshot.perProcess {
            for (kind, reading) in readings where !isFresh(reading) {
                perProcess[identity]?[kind] = nil
                staleKinds.insert(kind)
            }
        }
        perProcess = perProcess.filter { !$0.value.isEmpty }
        for kind in staleKinds {
            capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: "Advanced sample is stale")
        }
        // Helper counters are rated by their capture time, so an old capture would give a stale rate.
        let processMetrics = snapshot.perProcessSystemMetrics.filter { _, metrics in
            guard let capturedAt = metrics.capturedAt else { return true }
            return isRecent(capturedAt, maximumAge: Self.maximumProcessCounterAge)
        }
        let idleInterval = capabilities[.processNetwork]?.available == true ? snapshot.idleZeroInterval : nil
        return AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities,
                                       idleZeroInterval: idleInterval,
                                       perProcessSystemMetrics: processMetrics)
    }

    private func applyLocalNettopSnapshot(_ stream: NettopStreamSnapshot,
                                          before: [Int32: ProcessIdentity],
                                          after: [Int32: ProcessIdentity],
                                          identityFailure: String?,
                                          perProcess: inout [ProcessIdentity: [MetricKind: MetricReading]],
                                          capabilities: inout [MetricKind: MetricAvailability],
                                          idleZeroInterval: inout DateInterval?) {
        if stream.latestSequence > 0 { lastLocalNettopSequence = stream.latestSequence }
        switch stream.health {
        case .healthy:
            if let interval = stream.interval, interval.duration > 0 {
                if before.isEmpty && after.isEmpty {
                    for kind in Self.networkKinds {
                        capabilities[kind] = MetricAvailability(available: false, reason: .notCollected,
                                                                detail: identityFailure ?? "No process identities could be verified")
                    }
                } else {
                    idleZeroInterval = interval
                    perProcess = Self.rates(from: Array(stream.totalsByPID.values), interval: interval,
                                            before: before, after: after)
                    for kind in Self.networkKinds {
                        capabilities[kind] = MetricAvailability(available: true)
                    }
                }
            } else {
                for kind in Self.networkKinds {
                    capabilities[kind] = MetricAvailability(available: false, reason: .warmingUp,
                                                            detail: identityFailure ?? "Network stream warming up")
                }
            }
        case .warmingUp:
            for kind in Self.networkKinds {
                capabilities[kind] = MetricAvailability(available: false, reason: .warmingUp)
            }
        case .unavailable:
            for kind in Self.networkKinds {
                capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed,
                                                        detail: stream.error ?? "Local network stream unavailable")
            }
        }
    }

    private func applyPowermetricsResponse(_ power: HelperSampleResponse,
                                           at responseTime: Date,
                                           existingFresh: AdvancedMetricsSnapshot,
                                           system: inout [MetricKind: MetricReading],
                                           capabilities: inout [MetricKind: MetricAvailability]) {
        if power.error == nil, let data = power.output,
           abs(responseTime.timeIntervalSince(power.capturedAt)) <= Self.maximumSampleAge {
            let parsed = AdvancedMetricsParser.power(data)
            if let percent = parsed.gpuPercent {
                system[.gpu] = MetricReading(value: percent, unit: .percent, timestamp: power.capturedAt)
                capabilities[.gpu] = MetricAvailability(available: true)
            } else {
                capabilities[.gpu] = MetricAvailability(available: false, reason: .unsupported,
                                                        detail: "GPU activity schema unavailable")
            }
            if let watts = parsed.watts {
                system[.energy] = MetricReading(value: watts, unit: .watts, timestamp: power.capturedAt)
                capabilities[.energy] = MetricAvailability(available: true)
            } else {
                capabilities[.energy] = MetricAvailability(available: false, reason: .unsupported,
                                                           detail: "Combined or component power (mW) unavailable")
            }
        } else if Self.isTransientRateError(power.error) {
            if let cachedGPU = existingFresh.system[.gpu], existingFresh.capabilities[.gpu]?.available == true {
                system[.gpu] = cachedGPU
                capabilities[.gpu] = existingFresh.capabilities[.gpu]
            } else {
                capabilities[.gpu] = Self.failureAvailability(power.error, fallback: "GPU sample unavailable or stale")
            }
            if let cachedEnergy = existingFresh.system[.energy], existingFresh.capabilities[.energy]?.available == true {
                system[.energy] = cachedEnergy
                capabilities[.energy] = existingFresh.capabilities[.energy]
            } else {
                system[.energy] = nil
                capabilities[.energy] = Self.failureAvailability(power.error, fallback: "Power sample unavailable or stale")
            }
        } else {
            system[.gpu] = nil
            system[.energy] = nil
            for kind in [MetricKind.gpu, .energy] {
                capabilities[kind] = Self.failureAvailability(power.error, fallback: "Power sample unavailable or stale")
            }
        }
    }

    /// Per-process counters for identities that still match the lookup taken after the reply. Transient rate
    /// errors keep the previous counters; any other failure clears them.
    private static func processSystemMetrics(_ response: HelperSampleResponse,
                                             identities: [Int32: ProcessIdentity],
                                             previous: [ProcessIdentity: CollectedProcessSystemMetrics])
        -> [ProcessIdentity: CollectedProcessSystemMetrics] {
        if response.error == nil, let data = response.output,
           let payload = try? JSONDecoder().decode(HelperProcessMetricsPayload.self, from: data) {
            var result: [ProcessIdentity: CollectedProcessSystemMetrics] = [:]
            for entry in payload.entries {
                let identity = ProcessIdentity(
                    pid: entry.pid,
                    startTime: ProcessStartTime(secondsSinceEpoch: entry.startSeconds,
                                                microseconds: entry.startMicroseconds)
                )
                guard identities[entry.pid] == identity else { continue }
                result[identity] = CollectedProcessSystemMetrics(
                    cpuTotalNanoseconds: entry.cpuTotalNanoseconds,
                    memoryBytes: entry.memoryBytes,
                    diskReadBytes: entry.diskReadBytes,
                    diskWriteBytes: entry.diskWriteBytes,
                    threadCount: entry.threadCount,
                    executablePath: entry.executablePath,
                    capturedAt: response.capturedAt
                )
            }
            return result
        }
        return isTransientRateError(response.error) ? previous : [:]
    }

    private static func rates(from entries: [NettopDeltaEntry],
                              interval: DateInterval,
                              before: [Int32: ProcessIdentity],
                              after: [Int32: ProcessIdentity]) -> [ProcessIdentity: [MetricKind: MetricReading]] {
        let elapsed = max(0.05, interval.duration)
        var result: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard let identity = before[entry.pid], after[entry.pid] == identity else { continue }
            let rxRate = Double(entry.bytesIn) / elapsed
            let txRate = Double(entry.bytesOut) / elapsed
            let receive = MetricReading(value: rxRate, unit: .bytesPerSecond, timestamp: interval.end,
                                        measurementInterval: interval)
            let transmit = MetricReading(value: txRate, unit: .bytesPerSecond, timestamp: interval.end,
                                         measurementInterval: interval)
            let combined = MetricReading(value: rxRate + txRate, unit: .bytesPerSecond, timestamp: interval.end,
                                         measurementInterval: interval)
            result[identity] = [
                .processNetworkReceive: receive,
                .processNetworkTransmit: transmit,
                .processNetwork: combined
            ]
        }
        return result
    }

    private static func isTransientRateError(_ code: String?) -> Bool {
        code == "rateLimited" || code == "busy"
    }

    /// A failure that should slow the next helper refresh: any error that is neither "unavailable" nor transient.
    private static func isFailure(_ code: String?) -> Bool {
        code != nil && code != HelperSamplingClient.unavailableError && !isTransientRateError(code)
    }

    /// A missing helper is an optional feature that is not set up, not a failed collection.
    private static func failureAvailability(_ code: String?, fallback: String) -> MetricAvailability {
        MetricAvailability(available: false,
                           reason: code == HelperSamplingClient.unavailableError ? .notCollected : .collectionFailed,
                           detail: describe(helperError: code) ?? fallback)
    }

    /// Shown when a metric needs the optional helper and the helper is not installed, approved or signed.
    static let helperRequiredDetail = "Requires the optional privileged helper (Settings › Optional integrations)."

    /// Turns a helper or XPC failure code into text a person can act on. Unknown codes pass through.
    static func describe(helperError code: String?) -> String? {
        guard let code else { return nil }
        switch code {
        case HelperSamplingClient.unavailableError: return helperRequiredDetail
        case "rateLimited", "busy": return "The helper is busy; the next sample will retry."
        case "timedOut": return "The helper did not respond in time."
        case "disconnected", "connectionInterrupted", "connectionInvalidated", "connectionFailed":
            return "Microgravity could not reach the helper."
        case "incompatibleVersion", "incompatibleResponse", "protocolUnavailable":
            return "The helper is out of date. Remove it and set it up again in Settings."
        case "launchFailed", "commandFailed", "noData", "outputLimit", "readFailed":
            return "The helper's measurement command failed."
        default: return code
        }
    }
}
