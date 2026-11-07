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
    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse
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

/// A single in-flight helper sample is refreshed at most every five seconds.
/// Callers receive a cached snapshot immediately; readings retain capture timestamps.
actor NativeAdvancedMetricsCollector: AdvancedMetricsCollecting {
    /// Maximum age of a helper reading, measured from its capture time to read time.
    static let maximumSampleAge: TimeInterval = 30
    private static let maximumClockSkew: TimeInterval = 1

    private let client: any AdvancedSamplingClient
    private let now: @Sendable () -> Date
    private let processIdentities: @Sendable () -> ProcessIdentityLookup
    private var network = AdvancedNetworkAccumulator()
    private var cache = AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
        [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit, .processGPUTime, .gpu, .energy]
            .map { ($0, MetricAvailability(available: false, reason: .warmingUp)) }))
    private var lastCompleted: Date?
    private var inFlight = false
    private var refreshRequestCount = 0

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
        let refreshDue = lastCompleted.map {
            currentTime.timeIntervalSince($0) >= 5 || currentTime < $0
        } ?? true
        if !inFlight && refreshDue {
            inFlight = true
            refreshRequestCount += 1
            Task { await self.refresh() }
        }
        if let completed = lastCompleted, currentTime.timeIntervalSince(completed) > Self.maximumSampleAge {
            let unavailable = MetricAvailability(available: false, reason: .collectionFailed, detail: "Advanced sample is stale")
            return AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
                [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit, .processGPUTime, .gpu, .energy].map { ($0, unavailable) }))
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

    private func refresh() async {
        // Cleared on every exit path, including cancellation, so a stuck flag cannot stop future refreshes.
        defer { inFlight = false }
        let beforeLookup = processIdentities()
        let before = beforeLookup.identities
        async let networkResponse = client.sample(.nettop)
        async let powerResponse = client.sample(.powermetrics)
        let net = await networkResponse
        let afterLookup = processIdentities()
        let after = afterLookup.identities
        let power = await powerResponse
        let afterPower = processIdentities().identities
        let identityFailure = beforeLookup.failureDetail ?? afterLookup.failureDetail
        let responseTime = now()
        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var capabilities: [MetricKind: MetricAvailability] = [:]
        let networkKinds: [MetricKind] = [.processNetwork, .processNetworkReceive, .processNetworkTransmit]
        if net.error == nil, let data = net.output, data.count <= AdvancedMetricsParser.maximumBytes,
           abs(responseTime.timeIntervalSince(net.capturedAt)) <= Self.maximumSampleAge,
           let text = String(data: data, encoding: .utf8), AdvancedMetricsParser.hasNettopHeader(text) {
            perProcess = network.update(AdvancedMetricsParser.nettop(text), before: before, after: after, at: net.capturedAt)
            for kind in networkKinds {
                capabilities[kind] = perProcess.isEmpty
                    ? MetricAvailability(available: false, reason: .notCollected,
                                         detail: identityFailure ?? "No process identities could be verified")
                    : MetricAvailability(available: true)
            }
        } else {
            for kind in networkKinds { capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: net.error ?? "Network sample unavailable or invalid") }
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
                capabilities[.energy] = MetricAvailability(available: false, reason: .unsupported, detail: "Explicit component power units unavailable")
            }
            var gpuCount = 0
            for (pid, seconds) in parsed.processGPUSeconds {
                guard let identity = before[pid], afterPower[pid] == identity else { continue }
                perProcess[identity, default: [:]][.processGPUTime] = MetricReading(value: seconds, unit: .seconds, timestamp: power.capturedAt)
                gpuCount += 1
            }
            capabilities[.processGPUTime] = gpuCount > 0
                ? MetricAvailability(available: true)
                : MetricAvailability(available: false, reason: .unsupported, detail: "Explicit per-process GPU time units unavailable")
        } else {
            for kind in [MetricKind.gpu, .energy, .processGPUTime] {
                capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: power.error ?? "Power sample unavailable or stale")
            }
        }
        cache = AdvancedMetricsSnapshot(system: system, perProcess: perProcess, capabilities: capabilities)
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
