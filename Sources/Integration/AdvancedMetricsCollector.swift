import Darwin
import Foundation

struct AdvancedNetworkAccumulator {
    private enum Direction: Hashable { case receive, transmit }
    private struct Key: Hashable { let identity: ProcessIdentity; let direction: Direction }
    private var counters = CounterDeltaTracker<Key>()

    mutating func update(_ totals: [Int32: AdvancedMetricsParser.NetworkTotals],
                         before: [Int32: ProcessIdentity], after: [Int32: ProcessIdentity],
                         at timestamp: Date) -> [ProcessIdentity: [MetricKind: MetricReading]] {
        var result: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var retained = Set<Key>()
        for (pid, value) in totals {
            guard let identity = before[pid], after[pid] == identity else { continue }
            let receiveKey = Key(identity: identity, direction: .receive)
            let transmitKey = Key(identity: identity, direction: .transmit)
            retained.insert(receiveKey); retained.insert(transmitKey)
            let receive = counters.update(value.received, for: receiveKey, at: timestamp)
                .reading(unit: .bytesPerSecond, timestamp: timestamp) { Double($0) / $1 }
            let transmit = counters.update(value.sent, for: transmitKey, at: timestamp)
                .reading(unit: .bytesPerSecond, timestamp: timestamp) { Double($0) / $1 }
            let combined: MetricReading
            if let read = receive.value, let write = transmit.value, (read + write).isFinite {
                combined = MetricReading(value: read + write, unit: .bytesPerSecond, timestamp: timestamp)
            } else {
                combined = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                         reason: receive.unavailableReason ?? transmit.unavailableReason ?? .collectionFailed)
            }
            result[identity] = [.processNetworkReceive: receive, .processNetworkTransmit: transmit,
                                .processNetwork: combined]
        }
        counters.retain(retained)
        return result
    }
}

protocol AdvancedSamplingClient: Sendable {
    /// Runs once per refresh, before any sample. Returning false ends the refresh without sampling.
    func prepareRefresh() async -> Bool
    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse
    var supportsProtocolV2: Bool { get }
    func sample(_ kind: HelperSampleKind, sinceSequence: UInt64?) async -> HelperSampleResponse
}

extension AdvancedSamplingClient {
    func prepareRefresh() async -> Bool { true }
    var supportsProtocolV2: Bool { false }
    func sample(_ kind: HelperSampleKind, sinceSequence: UInt64?) async -> HelperSampleResponse {
        await sample(kind)
    }
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

/// Coordinates privileged helper sampling (v1 5s or v2 1s streaming) plus optional unprivileged nettop fallback.
actor NativeAdvancedMetricsCollector: AdvancedMetricsCollecting {
    /// Maximum age of a helper reading, measured from its capture time to read time.
    static let maximumSampleAge: TimeInterval = 30
    /// Minimum spacing between refreshes while using legacy v1 polling or powermetrics.
    static let refreshInterval: TimeInterval = 5
    /// Minimum spacing between fast 1s refreshes for streaming nettop and helper process metrics.
    static let fastRefreshInterval: TimeInterval = 0.9
    /// Minimum spacing between helper availability rechecks when the helper is absent.
    static let helperUnavailableRetryInterval: TimeInterval = 60
    private static let maximumClockSkew: TimeInterval = 1
    private static let networkKinds: [MetricKind] = [.processNetwork, .processNetworkReceive, .processNetworkTransmit]
    private static let sampledKinds: [MetricKind] = networkKinds + [.gpu, .energy]
    /// No verified powermetrics output provides per-process GPU time, so it is never collected.
    static let processGPUTimeAvailability = MetricAvailability(available: false, reason: .unsupported,
                                                               detail: "Per-process GPU time is not collected.")

    private let client: any AdvancedSamplingClient
    private let localNettopStream: NettopStreamService?
    private let shouldSamplePowermetrics: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let processIdentities: @Sendable () -> ProcessIdentityLookup
    private var network = AdvancedNetworkAccumulator()
    private var cache = AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
        NativeAdvancedMetricsCollector.sampledKinds.map { ($0, MetricAvailability(available: false, reason: .warmingUp)) }
            + [(MetricKind.processGPUTime, NativeAdvancedMetricsCollector.processGPUTimeAvailability)]))
    private var lastCompleted: Date?
    private var lastHelperCheck: Date?
    private var lastPowermetricsSampleAt: Date?
    private var lastHelperNettopSequence: UInt64?
    private var lastLocalNettopSequence: UInt64?
    private var lastResultWasHelperUnavailable = false
    /// Set by retryHelperSoon(); honored only while the last result was helper-unavailable.
    private var helperRetryRequested = false
    private var inFlight = false
    private var refreshRequestCount = 0
    private var refreshCompletionCount = 0

    init(client: any AdvancedSamplingClient = HelperSamplingClient(),
         localNettopStream: NettopStreamService? = nil,
         shouldSamplePowermetrics: @escaping @Sendable () -> Bool = { true },
         now: @escaping @Sendable () -> Date = { Date() },
         processIdentities: (@Sendable () -> [Int32: ProcessIdentity])? = nil,
         processIdentityLookup: (@Sendable () -> ProcessIdentityLookup)? = nil) {
        self.client = client
        self.localNettopStream = localNettopStream
        self.shouldSamplePowermetrics = shouldSamplePowermetrics
        self.now = now
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

    /// Asks for a refresh on the next collect, skipping the helper-unavailable backoff. Used when the app becomes
    /// active, since the user may have just approved the helper in System Settings. No effect on a healthy helper.
    func retryHelperSoon() {
        guard lastResultWasHelperUnavailable else { return }
        helperRetryRequested = true
    }

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        let currentTime = now()
        if !client.supportsProtocolV2 && localNettopStream == nil {
            return await collectLegacySnapshot(at: currentTime)
        }

        let helperRecheckDue = helperRetryRequested || !lastResultWasHelperUnavailable || (lastHelperCheck.map {
            currentTime.timeIntervalSince($0) >= Self.helperUnavailableRetryInterval || currentTime < $0
        } ?? true)

        let effectiveInterval = (!lastResultWasHelperUnavailable || localNettopStream != nil)
            ? Self.fastRefreshInterval
            : Self.helperUnavailableRetryInterval
        let refreshDue = helperRetryRequested || (lastCompleted.map {
            currentTime.timeIntervalSince($0) >= effectiveInterval || currentTime < $0
        } ?? true)

        if !inFlight && refreshDue {
            inFlight = true
            helperRetryRequested = false
            refreshRequestCount += 1
            let shouldProbeHelper = helperRecheckDue
            Task { await self.refreshV2(probeHelper: shouldProbeHelper) }
        }

        if !lastResultWasHelperUnavailable || localNettopStream != nil, let completed = lastCompleted,
           currentTime.timeIntervalSince(completed) > Self.maximumSampleAge {
            let unavailable = MetricAvailability(available: false, reason: .collectionFailed, detail: "Advanced sample is stale")
            var capabilities = Dictionary(uniqueKeysWithValues: Self.sampledKinds.map { ($0, unavailable) })
            capabilities[.processGPUTime] = Self.processGPUTimeAvailability
            return AdvancedMetricsSnapshot(capabilities: capabilities)
        }
        return freshReadings(in: cache, at: currentTime)
    }

    private func collectLegacySnapshot(at currentTime: Date) async -> AdvancedMetricsSnapshot {
        let interval = lastResultWasHelperUnavailable ? Self.helperUnavailableRetryInterval : Self.refreshInterval
        let retryNow = helperRetryRequested && lastResultWasHelperUnavailable
        let refreshDue = retryNow || (lastCompleted.map {
            currentTime.timeIntervalSince($0) >= interval || currentTime < $0
        } ?? true)
        if !inFlight && refreshDue {
            inFlight = true
            helperRetryRequested = false
            refreshRequestCount += 1
            Task { await self.refreshLegacy() }
        }
        if !lastResultWasHelperUnavailable, let completed = lastCompleted,
           currentTime.timeIntervalSince(completed) > Self.maximumSampleAge {
            let unavailable = MetricAvailability(available: false, reason: .collectionFailed, detail: "Advanced sample is stale")
            var capabilities = Dictionary(uniqueKeysWithValues: Self.sampledKinds.map { ($0, unavailable) })
            capabilities[.processGPUTime] = Self.processGPUTimeAvailability
            return AdvancedMetricsSnapshot(capabilities: capabilities)
        }
        return freshReadings(in: cache, at: currentTime)
    }

    /// Drops readings whose own capture time is older than `maximumSampleAge` (or implausibly in the future)
    /// and marks their kinds unavailable, so a cached refresh cannot outlive its helper samples.
    private func freshReadings(in snapshot: AdvancedMetricsSnapshot, at currentTime: Date) -> AdvancedMetricsSnapshot {
        func isFresh(_ reading: MetricReading) -> Bool {
            let age = currentTime.timeIntervalSince(reading.timestamp)
            return age <= Self.maximumSampleAge && age >= -Self.maximumClockSkew
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
        let idleInterval = capabilities[.processNetwork]?.available == true ? snapshot.idleZeroInterval : nil
        return AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities,
                                       idleZeroInterval: idleInterval,
                                       perProcessSystemMetrics: snapshot.perProcessSystemMetrics)
    }

    func refreshRequestCountForTesting() -> Int { refreshRequestCount }
    func refreshCompletionCountForTesting() -> Int { refreshCompletionCount }

    private func refreshLegacy() async {
        defer { inFlight = false; refreshCompletionCount += 1 }
        guard await client.prepareRefresh() else {
            recordHelperUnavailable()
            return
        }
        let beforeLookup = processIdentities()
        let before = beforeLookup.identities
        async let networkResponse = client.sample(.nettop)
        async let powerResponse = client.sample(.powermetrics)
        let net = await networkResponse
        let afterLookup = processIdentities()
        let after = afterLookup.identities
        let power = await powerResponse
        let identityFailure = beforeLookup.failureDetail ?? afterLookup.failureDetail
        let responseTime = now()
        let existingFresh = freshReadings(in: cache, at: responseTime)

        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var capabilities: [MetricKind: MetricAvailability] = [:]
        if net.error == nil, let data = net.output, data.count <= AdvancedMetricsParser.maximumBytes,
           abs(responseTime.timeIntervalSince(net.capturedAt)) <= Self.maximumSampleAge,
           let text = String(data: data, encoding: .utf8), AdvancedMetricsParser.hasNettopHeader(text) {
            perProcess = network.update(AdvancedMetricsParser.nettop(text), before: before, after: after, at: net.capturedAt)
            for kind in Self.networkKinds {
                capabilities[kind] = perProcess.isEmpty
                    ? MetricAvailability(available: false, reason: .notCollected,
                                         detail: identityFailure ?? "No process identities could be verified")
                    : MetricAvailability(available: true)
            }
        } else if Self.isTransientRateError(net.error),
                  !existingFresh.perProcess.isEmpty,
                  existingFresh.capabilities[.processNetwork]?.available == true {
            perProcess = existingFresh.perProcess
            for kind in Self.networkKinds {
                capabilities[kind] = existingFresh.capabilities[kind] ?? MetricAvailability(available: true)
            }
        } else {
            for kind in Self.networkKinds {
                capabilities[kind] = Self.failureAvailability(net.error, fallback: "Network sample unavailable or invalid")
            }
        }

        var system: [MetricKind: MetricReading] = [:]
        applyPowermetricsResponse(power, at: responseTime, existingFresh: existingFresh,
                                  system: &system, capabilities: &capabilities)

        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        lastResultWasHelperUnavailable = net.error == HelperSamplingClient.unavailableError
            || power.error == HelperSamplingClient.unavailableError
        cache = AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities)
        lastCompleted = now()
        if !lastResultWasHelperUnavailable { helperRetryRequested = false }
    }

    private func refreshV2(probeHelper: Bool) async {
        defer { inFlight = false; refreshCompletionCount += 1 }
        let responseTime = now()
        let existingFresh = freshReadings(in: cache, at: responseTime)

        var helperReady = false
        if probeHelper {
            lastHelperCheck = responseTime
            helperReady = await client.prepareRefresh()
        } else {
            helperReady = !lastResultWasHelperUnavailable
        }

        guard helperReady else {
            lastResultWasHelperUnavailable = true
            collectUnprivilegedFallback(at: responseTime)
            return
        }

        let beforeLookup = processIdentities()
        let before = beforeLookup.identities
        let shouldPollPowermetrics = shouldSamplePowermetrics() && (lastPowermetricsSampleAt.map {
            responseTime.timeIntervalSince($0) >= Self.refreshInterval || responseTime < $0
        } ?? true)

        async let streamResponse = client.sample(.nettopStream, sinceSequence: lastHelperNettopSequence)
        async let processResponse = client.sample(.processMetrics, sinceSequence: nil)
        let netResponse = await streamResponse
        let helperProcResponse = await processResponse
        let afterLookup = processIdentities()
        let after = afterLookup.identities
        let identityFailure = beforeLookup.failureDetail ?? afterLookup.failureDetail

        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var capabilities: [MetricKind: MetricAvailability] = [:]
        var idleZeroInterval: DateInterval?
        var perProcessSystemMetrics: [ProcessIdentity: CollectedProcessSystemMetrics] = [:]

        var networkHandledByHelper = false
        if netResponse.error == nil,
           let output = netResponse.output,
           abs(responseTime.timeIntervalSince(netResponse.capturedAt)) <= Self.maximumSampleAge,
           let payload = try? JSONDecoder().decode(HelperNettopStreamPayload.self, from: output) {
            networkHandledByHelper = true
            if payload.sequence > 0 { lastHelperNettopSequence = payload.sequence }
            switch payload.health {
            case .healthy:
                if let start = payload.intervalStart, let end = payload.intervalEnd, end > start {
                    let interval = DateInterval(start: start, end: end)
                    if before.isEmpty && after.isEmpty {
                        for kind in Self.networkKinds {
                            capabilities[kind] = MetricAvailability(available: false, reason: .notCollected,
                                                                    detail: identityFailure ?? "No process identities could be verified")
                        }
                    } else {
                        idleZeroInterval = interval
                        perProcess = Self.rates(from: payload.entries, interval: interval, before: before, after: after)
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
                    capabilities[kind] = Self.failureAvailability(payload.detail, fallback: "Network stream unavailable")
                }
            }
        } else if Self.isTransientRateError(netResponse.error),
                  existingFresh.capabilities[.processNetwork]?.available == true {
            networkHandledByHelper = true
            perProcess = existingFresh.perProcess
            idleZeroInterval = existingFresh.idleZeroInterval
            for kind in Self.networkKinds {
                capabilities[kind] = existingFresh.capabilities[kind] ?? MetricAvailability(available: true)
            }
        }

        if !networkHandledByHelper {
            if let localStream = localNettopStream,
               !Self.isTransientRateError(netResponse.error) {
                let localSnapshot = localStream.latestSnapshot(since: lastLocalNettopSequence, now: responseTime)
                applyLocalNettopSnapshot(localSnapshot, before: before, after: after,
                                         identityFailure: identityFailure,
                                         perProcess: &perProcess, capabilities: &capabilities,
                                         idleZeroInterval: &idleZeroInterval)
            } else {
                for kind in Self.networkKinds {
                    capabilities[kind] = Self.failureAvailability(netResponse.error, fallback: "Network sample unavailable")
                }
            }
        }

        if helperProcResponse.error == nil,
           let procData = helperProcResponse.output,
           let payload = try? JSONDecoder().decode(HelperProcessMetricsPayload.self, from: procData) {
            for entry in payload.entries {
                let identity = ProcessIdentity(
                    pid: entry.pid,
                    startTime: ProcessStartTime(secondsSinceEpoch: entry.startSeconds,
                                                microseconds: entry.startMicroseconds)
                )
                guard before[entry.pid] == identity || after[entry.pid] == identity else { continue }
                perProcessSystemMetrics[identity] = CollectedProcessSystemMetrics(
                    cpuTotalNanoseconds: entry.cpuTotalNanoseconds,
                    memoryBytes: entry.memoryBytes,
                    diskReadBytes: entry.diskReadBytes,
                    diskWriteBytes: entry.diskWriteBytes,
                    threadCount: entry.threadCount,
                    executablePath: entry.executablePath
                )
            }
        } else if Self.isTransientRateError(helperProcResponse.error) {
            perProcessSystemMetrics = existingFresh.perProcessSystemMetrics
        }

        var system = existingFresh.system
        if shouldPollPowermetrics {
            let power = await client.sample(.powermetrics, sinceSequence: nil)
            lastPowermetricsSampleAt = responseTime
            applyPowermetricsResponse(power, at: responseTime, existingFresh: existingFresh,
                                      system: &system, capabilities: &capabilities)
        } else if let gpuCap = existingFresh.capabilities[.gpu], let energyCap = existingFresh.capabilities[.energy] {
            capabilities[.gpu] = gpuCap
            capabilities[.energy] = energyCap
        } else {
            capabilities[.gpu] = MetricAvailability(available: false, reason: .unsupported)
            capabilities[.energy] = MetricAvailability(available: false, reason: .unsupported)
        }

        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        lastResultWasHelperUnavailable = netResponse.error == HelperSamplingClient.unavailableError
            || helperProcResponse.error == HelperSamplingClient.unavailableError
        cache = AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities,
                                        idleZeroInterval: idleZeroInterval,
                                        perProcessSystemMetrics: perProcessSystemMetrics)
        lastCompleted = now()
        if !lastResultWasHelperUnavailable { helperRetryRequested = false }
    }

    private func collectUnprivilegedFallback(at responseTime: Date) {
        let unavailableHelper = MetricAvailability(available: false, reason: .notCollected,
                                                   detail: Self.helperRequiredDetail)
        var capabilities = Dictionary(uniqueKeysWithValues: Self.sampledKinds.map { ($0, unavailableHelper) })
        capabilities[.processGPUTime] = Self.processGPUTimeAvailability

        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var idleZeroInterval: DateInterval?

        if let localNettopStream {
            let beforeLookup = processIdentities()
            let streamSnapshot = localNettopStream.latestSnapshot(since: lastLocalNettopSequence, now: responseTime)
            let afterLookup = processIdentities()
            let identityFailure = beforeLookup.failureDetail ?? afterLookup.failureDetail
            applyLocalNettopSnapshot(streamSnapshot,
                                     before: beforeLookup.identities,
                                     after: afterLookup.identities,
                                     identityFailure: identityFailure,
                                     perProcess: &perProcess,
                                     capabilities: &capabilities,
                                     idleZeroInterval: &idleZeroInterval)
        }

        cache = AdvancedMetricsSnapshot(perProcess: perProcess, capabilities: capabilities,
                                        idleZeroInterval: idleZeroInterval)
        lastCompleted = now()
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
                    let entries = stream.totalsByPID.values.map {
                        HelperNettopDeltaEntry(pid: $0.pid, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)
                    }
                    perProcess = Self.rates(from: entries, interval: interval, before: before, after: after)
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

    private static func rates(from entries: [HelperNettopDeltaEntry],
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

    private func recordHelperUnavailable() {
        let unavailable = MetricAvailability(available: false, reason: .notCollected,
                                             detail: Self.helperRequiredDetail)
        var capabilities = Dictionary(uniqueKeysWithValues: Self.sampledKinds.map { ($0, unavailable) })
        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        cache = AdvancedMetricsSnapshot(capabilities: capabilities)
        lastResultWasHelperUnavailable = true
        lastCompleted = now()
    }
}
