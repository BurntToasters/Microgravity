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

/// A single in-flight helper sample is refreshed at most every five seconds.
/// Callers receive a cached snapshot immediately; readings retain capture timestamps.
actor NativeAdvancedMetricsCollector: AdvancedMetricsCollecting {
    private let client: any AdvancedSamplingClient
    private var network = AdvancedNetworkAccumulator()
    private var cache = AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
        [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit, .processGPUTime, .gpu, .energy]
            .map { ($0, MetricAvailability(available: false, reason: .warmingUp)) }))
    private var lastStart: Date?
    private var lastCompleted: Date?
    private var inFlight = false

    init(client: any AdvancedSamplingClient = HelperSamplingClient()) { self.client = client }

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        let now = Date()
        if !inFlight && (lastStart == nil || now.timeIntervalSince(lastStart!) >= 5 || now < lastStart!) {
            inFlight = true
            lastStart = now
            Task { await self.refresh() }
        }
        if let completed = lastCompleted, now.timeIntervalSince(completed) > 30 {
            let unavailable = MetricAvailability(available: false, reason: .collectionFailed, detail: "Advanced sample is stale")
            return AdvancedMetricsSnapshot(capabilities: Dictionary(uniqueKeysWithValues:
                [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit, .processGPUTime, .gpu, .energy].map { ($0, unavailable) }))
        }
        return cache
    }

    private func refresh() async {
        let before = Self.identities()
        async let networkResponse = client.sample(.nettop)
        async let powerResponse = client.sample(.powermetrics)
        let net = await networkResponse
        let after = Self.identities()
        let power = await powerResponse
        let afterPower = Self.identities()
        let now = Date()
        var perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:]
        var capabilities: [MetricKind: MetricAvailability] = [:]
        let networkKinds: [MetricKind] = [.processNetwork, .processNetworkReceive, .processNetworkTransmit]
        if net.error == nil, let data = net.output, data.count <= AdvancedMetricsParser.maximumBytes,
           abs(now.timeIntervalSince(net.capturedAt)) <= 30,
           let text = String(data: data, encoding: .utf8), AdvancedMetricsParser.hasNettopHeader(text) {
            perProcess = network.update(AdvancedMetricsParser.nettop(text), before: before, after: after, at: net.capturedAt)
            for kind in networkKinds {
                capabilities[kind] = perProcess.isEmpty
                    ? MetricAvailability(available: false, reason: .notCollected, detail: "No process identities could be verified")
                    : MetricAvailability(available: true)
            }
        } else {
            network = AdvancedNetworkAccumulator()
            for kind in networkKinds { capabilities[kind] = MetricAvailability(available: false, reason: .collectionFailed, detail: net.error ?? "Network sample unavailable or invalid") }
        }
        var system: [MetricKind: MetricReading] = [:]
        if power.error == nil, let data = power.output, abs(now.timeIntervalSince(power.capturedAt)) <= 30 {
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
        lastCompleted = Date()
        inFlight = false
    }

    private static func identities() -> [Int32: ProcessIdentity] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0, size <= 4 * 1024 * 1024 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 256)
        let byteCount = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard byteCount > 0, Int(byteCount) < pids.count * MemoryLayout<pid_t>.size else { return [:] }
        var result: [Int32: ProcessIdentity] = [:]
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { continue }
            result[pid] = ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: Int64(info.pbi_start_tvsec), microseconds: Int32(info.pbi_start_tvusec)))
        }
        return result
    }
}
