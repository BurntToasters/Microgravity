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

/// A single in-flight helper refresh runs at most every five seconds, or every sixty seconds while
/// the helper is unavailable. Callers receive a cached snapshot immediately; readings retain capture timestamps.
actor NativeAdvancedMetricsCollector: AdvancedMetricsCollecting {
    /// Maximum age of a helper reading, measured from its capture time to read time.
    static let maximumSampleAge: TimeInterval = 30
    /// Minimum spacing between refreshes while the helper responds.
    static let refreshInterval: TimeInterval = 5
    /// Minimum spacing between refreshes after a refresh found the helper unavailable.
    static let helperUnavailableRetryInterval: TimeInterval = 60
    private static let maximumClockSkew: TimeInterval = 1
    private static let networkKinds: [MetricKind] = [.processNetwork, .processNetworkReceive, .processNetworkTransmit]
    private static let sampledKinds: [MetricKind] = networkKinds + [.gpu, .energy]
    /// No verified powermetrics output provides per-process GPU time, so it is never collected.
    static let processGPUTimeAvailability = MetricAvailability(available: false, reason: .unsupported,
                                                               detail: "Per-process GPU time is not collected.")

    private let client: any AdvancedSamplingClient
    private let now: @Sendable () -> Date
    private let processIdentities: @Sendable () -> ProcessIdentityLookup
    private var network = AdvancedNetworkAccumulator()
    private var cache = AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
        NativeAdvancedMetricsCollector.sampledKinds.map { ($0, MetricAvailability(available: false, reason: .warmingUp)) }
            + [(MetricKind.processGPUTime, NativeAdvancedMetricsCollector.processGPUTimeAvailability)]))
    private var lastCompleted: Date?
    private var lastResultWasHelperUnavailable = false
    private var inFlight = false
    private var refreshRequestCount = 0
    private var refreshCompletionCount = 0

    init(client: any AdvancedSamplingClient = HelperSamplingClient(),
         now: @escaping @Sendable () -> Date = { Date() },
         processIdentities: (@Sendable () -> [Int32: ProcessIdentity])? = nil,
         processIdentityLookup: (@Sendable () -> ProcessIdentityLookup)? = nil) {
        self.client = client
        self.now = now
        let lookup: @Sendable () -> ProcessIdentityLookup
        if let processIdentityLookup {
            lookup = processIdentityLookup
        } else if let processIdentities {
            lookup = { ProcessIdentityLookup(identities: processIdentities()) }
        } else {
            lookup = { Self.identityLookup() }
        }
        self.processIdentities = lookup
    }

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        let currentTime = now()
        let interval = lastResultWasHelperUnavailable ? Self.helperUnavailableRetryInterval : Self.refreshInterval
        let refreshDue = lastCompleted.map {
            currentTime.timeIntervalSince($0) >= interval || currentTime < $0
        } ?? true
        if !inFlight && refreshDue {
            inFlight = true
            refreshRequestCount += 1
            Task { await self.refresh() }
        }
        // An unavailable-helper cache holds no readings to age out, and its cached reason stays accurate.
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
        return AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities)
    }

    func refreshRequestCountForTesting() -> Int { refreshRequestCount }
    func refreshCompletionCountForTesting() -> Int { refreshCompletionCount }

    private func refresh() async {
        // Cleared on every exit path, including cancellation, so a stuck flag cannot stop future refreshes.
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
        } else {
            for kind in Self.networkKinds { capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: net.error ?? "Network sample unavailable or invalid") }
        }
        var system: [MetricKind: MetricReading] = [:]
        if power.error == nil, let data = power.output, abs(responseTime.timeIntervalSince(power.capturedAt)) <= Self.maximumSampleAge {
            let parsed = AdvancedMetricsParser.power(data)
            if let percent = parsed.gpuPercent {
                system[.gpu] = MetricReading(value: percent, unit: .percent, timestamp: power.capturedAt)
                capabilities[.gpu] = MetricAvailability(available: true)
            } else {
                capabilities[.gpu] = MetricAvailability(available: false, reason: .unsupported, detail: "GPU activity schema unavailable")
            }
            if let watts = parsed.watts {
                system[.energy] = MetricReading(value: watts, unit: .watts, timestamp: power.capturedAt)
                capabilities[.energy] = MetricAvailability(available: true)
            } else {
                capabilities[.energy] = MetricAvailability(available: false, reason: .unsupported, detail: "Combined or component power (mW) unavailable")
            }
        } else {
            for kind in [MetricKind.gpu, .energy] {
                capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: power.error ?? "Power sample unavailable or stale")
            }
        }
        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        lastResultWasHelperUnavailable = net.error == HelperSamplingClient.unavailableError
            || power.error == HelperSamplingClient.unavailableError
        cache = AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities)
        lastCompleted = now()
    }

    private func recordHelperUnavailable() {
        let unavailable = MetricAvailability(available: false, reason: .collectionFailed,
                                             detail: HelperSamplingClient.unavailableError)
        var capabilities = Dictionary(uniqueKeysWithValues: Self.sampledKinds.map { ($0, unavailable) })
        capabilities[.processGPUTime] = Self.processGPUTimeAvailability
        cache = AdvancedMetricsSnapshot(capabilities: capabilities)
        lastResultWasHelperUnavailable = true
        lastCompleted = now()
    }

    /// proc_listpids sizes above this are not enumerated; identities for advanced metrics are then unverified.
    static let maximumIdentityListBytes = 4 * 1024 * 1024

    private static func identityLookup() -> ProcessIdentityLookup {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else {
            return ProcessIdentityLookup(identities: [:], failureDetail: "proc_listpids could not size the process list")
        }
        guard size <= maximumIdentityListBytes else {
            return ProcessIdentityLookup(identities: [:], failureDetail: "Process list is \(size) bytes, above the \(maximumIdentityListBytes / (1024 * 1024)) MiB identity cap; process identities were not verified")
        }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 256)
        let byteCount = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard byteCount > 0, Int(byteCount) < pids.count * MemoryLayout<pid_t>.size else {
            return ProcessIdentityLookup(identities: [:], failureDetail: "The process list changed during identity enumeration")
        }
        var result: [Int32: ProcessIdentity] = [:]
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { continue }
            result[pid] = ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: Int64(info.pbi_start_tvsec), microseconds: Int32(info.pbi_start_tvusec)))
        }
        return ProcessIdentityLookup(identities: result)
    }
}
