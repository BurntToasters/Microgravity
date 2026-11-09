#if DEBUG
import Darwin
import Foundation

struct FixtureConfiguration: Sendable {
    let staleTarget: Bool
    let gpuUnavailable: Bool
    let energyUnavailable: Bool
    let historyGap: Bool
    let incompleteDiscovery: Bool
    let networkUnavailable: Bool
    let duplicateGroups: Bool
    let refreshPulse: Bool
    let successfulForceQuit: Bool

    init(arguments: [String]) {
        let flags = Set(arguments)
        staleTarget = flags.contains("--ui-test-stale-target")
        gpuUnavailable = flags.contains("--ui-test-gpu-unavailable")
        energyUnavailable = flags.contains("--ui-test-energy-unavailable")
        historyGap = flags.contains("--ui-test-history-gap")
        incompleteDiscovery = flags.contains("--ui-test-incomplete-discovery")
        networkUnavailable = flags.contains("--ui-test-network-unavailable")
        duplicateGroups = flags.contains("--ui-test-duplicate-groups")
        refreshPulse = flags.contains("--ui-test-refresh-pulse")
        successfulForceQuit = flags.contains("--ui-test-successful-force-quit")
    }
}

@MainActor
final class FixtureMonitoringStore: MonitoringStore {
    private(set) var latestSnapshot: MonitoringSnapshot?
    private(set) var graphSamples: [MonitoringGraphSample] = []
    private(set) var interval: MonitoringInterval = .oneSecond
    private(set) var isPaused = false
    private(set) var isRunning = false
    var onSnapshot: (@MainActor @Sendable (MonitoringSnapshot) -> Void)?

    private let configuration: FixtureConfiguration
    private let refreshPulseInitialDelayNanoseconds: UInt64
    private let refreshPulseIntervalNanoseconds: UInt64
    private var refreshPulseTask: Task<Void, Never>?
    private var refreshPulseGeneration = 0
    private var nextRefreshSampleIndex = 30

    init(configuration: FixtureConfiguration,
         refreshPulseInitialDelayNanoseconds: UInt64 = 8_000_000_000,
         refreshPulseIntervalNanoseconds: UInt64 = 5_000_000_000) {
        self.configuration = configuration
        self.refreshPulseInitialDelayNanoseconds = refreshPulseInitialDelayNanoseconds
        self.refreshPulseIntervalNanoseconds = refreshPulseIntervalNanoseconds
        let now = Date()
        latestSnapshot = FixtureMonitoringStore.makeSnapshot(configuration: configuration, timestamp: now, sampleIndex: 29)
        graphSamples = (0..<30).map { index in
            let timestamp = now.addingTimeInterval(Double(index - 29))
            return MonitoringGraphSample(snapshot: FixtureMonitoringStore.makeSnapshot(
                configuration: configuration, timestamp: timestamp, sampleIndex: index
            ))
        }
    }

    func start(interval: MonitoringInterval) {
        cancelRefreshPulse()
        self.interval = interval
        isRunning = true
        isPaused = false
        if let latestSnapshot { onSnapshot?(latestSnapshot) }
        scheduleRefreshPulse()
    }

    func setInterval(_ interval: MonitoringInterval) { self.interval = interval }

    func pause() {
        isPaused = true
        cancelRefreshPulse()
        if let latestSnapshot { onSnapshot?(latestSnapshot) }
    }

    func resume() {
        isPaused = false
        isRunning = true
        if let latestSnapshot { onSnapshot?(latestSnapshot) }
        scheduleRefreshPulse()
    }

    func stop() {
        cancelRefreshPulse()
        isPaused = false
        isRunning = false
    }

    private func scheduleRefreshPulse() {
        guard configuration.refreshPulse, isRunning, !isPaused else { return }
        refreshPulseGeneration &+= 1
        let generation = refreshPulseGeneration
        let initialDelay = refreshPulseInitialDelayNanoseconds
        let interval = refreshPulseIntervalNanoseconds
        refreshPulseTask = Task { @MainActor [weak self] in
            var isFirstPulse = true
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: isFirstPulse ? initialDelay : interval)
                } catch {
                    return
                }
                guard let self,
                      generation == self.refreshPulseGeneration,
                      self.isRunning,
                      !self.isPaused else { return }
                isFirstPulse = false
                let sampleIndex = self.nextRefreshSampleIndex
                self.nextRefreshSampleIndex += 1
                let snapshot = Self.makeSnapshot(configuration: self.configuration,
                                                 timestamp: Date(), sampleIndex: sampleIndex)
                self.latestSnapshot = snapshot
                self.onSnapshot?(snapshot)
            }
        }
    }

    private func cancelRefreshPulse() {
        refreshPulseGeneration &+= 1
        refreshPulseTask?.cancel()
        refreshPulseTask = nil
    }

    func refreshNow() async {
        guard !isPaused, let latestSnapshot else { return }
        onSnapshot?(latestSnapshot)
    }

    func resetHistory() async throws {
        guard let latestSnapshot else { return }
        let reset = MonitoringSnapshot(timestamp: latestSnapshot.timestamp,
                                       system: latestSnapshot.system,
                                       processes: latestSnapshot.processes,
                                       processGroups: latestSnapshot.processGroups,
                                       startupItems: latestSnapshot.startupItems,
                                       services: latestSnapshot.services,
                                       users: latestSnapshot.users,
                                       discoveryCoverage: latestSnapshot.discoveryCoverage,
                                       capabilities: latestSnapshot.capabilities,
                                       advancedMetrics: latestSnapshot.advancedMetrics,
                                       history: [], applicationHistory: [])
        self.latestSnapshot = reset
        onSnapshot?(reset)
    }

    func removeProcessForFixtureAction(_ identity: ProcessIdentity) {
        guard let snapshot = latestSnapshot,
              snapshot.processes.contains(where: { $0.id == identity }) else { return }

        let processes = snapshot.processes.filter { $0.id != identity }
        let groups = snapshot.processGroups.compactMap { group -> ProcessGroupSnapshot? in
            let members = group.members.filter { $0 != identity }
            guard !members.isEmpty else { return nil }
            return ProcessGroupSnapshot(
                id: group.id,
                title: group.title,
                ownerUID: group.ownerUID,
                executablePath: group.executablePath,
                association: group.association,
                historyIdentity: group.historyIdentity,
                members: members,
                cpuPercent: group.cpuPercent,
                memoryBytes: group.memoryBytes,
                diskReadBytesPerSecond: group.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: group.diskWriteBytesPerSecond,
                networkReceiveBytesPerSecond: group.networkReceiveBytesPerSecond,
                networkTransmitBytesPerSecond: group.networkTransmitBytesPerSecond
            )
        }
        let updated = MonitoringSnapshot(
            timestamp: snapshot.timestamp,
            system: snapshot.system,
            processes: processes,
            processGroups: groups,
            startupItems: snapshot.startupItems,
            services: snapshot.services,
            users: snapshot.users,
            discoveryCoverage: snapshot.discoveryCoverage,
            capabilities: snapshot.capabilities,
            advancedMetrics: snapshot.advancedMetrics,
            history: snapshot.history,
            applicationHistory: snapshot.applicationHistory
        )
        latestSnapshot = updated
        onSnapshot?(updated)
    }

    private static func makeSnapshot(configuration: FixtureConfiguration, timestamp: Date,
                                      sampleIndex: Int) -> MonitoringSnapshot {
        let uid = UInt32(getuid())
        let editorIdentity = identity(pid: 410, offset: 1)
        let rendererIdentity = identity(pid: 411, offset: 2)
        let indexerIdentity = identity(pid: 620, offset: 3)
        let editorHistory = ApplicationHistoryIdentity(id: "fixture-editor", name: "Fixture Editor",
                                                       executablePath: "/Applications/Fixture Editor.app",
                                                       association: .applicationBundle)
        let indexerHistory = ApplicationHistoryIdentity(id: "fixture-indexer", name: "Fixture Indexer",
                                                        executablePath: "/Applications/Fixture Indexer.app",
                                                        association: .applicationBundle)

        let editor = ProcessSnapshot(
            id: editorIdentity, parentIdentity: nil, childIdentities: [rendererIdentity],
            name: "Fixture Editor Renderer", executablePath: "/Applications/Fixture Editor.app/Contents/MacOS/Renderer",
            ownerUID: uid, isCurrentUser: true,
            cpuPercent: reading(23 + Double(sampleIndex % 6) * 2, .percent, timestamp),
            memoryBytes: reading(420_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(245_000, .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(53_000, .bytesPerSecond, timestamp),
            diskReadTotalBytes: reading(80_000_000, .bytes, timestamp),
            diskWriteTotalBytes: reading(20_000_000, .bytes, timestamp),
            advancedMetrics: processAdvancedMetrics(configuration: configuration, timestamp: timestamp)
        )
        let renderer = ProcessSnapshot(
            id: rendererIdentity, parentIdentity: editorIdentity, childIdentities: [],
            name: "Fixture Renderer Worker", executablePath: "/Applications/Fixture Editor.app/Contents/Frameworks/Renderer",
            ownerUID: uid, isCurrentUser: true,
            cpuPercent: reading(9 + Double(sampleIndex % 4), .percent, timestamp),
            memoryBytes: reading(180_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(81_000, .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(12_000, .bytesPerSecond, timestamp),
            diskReadTotalBytes: reading(32_000_000, .bytes, timestamp),
            diskWriteTotalBytes: reading(7_000_000, .bytes, timestamp),
            advancedMetrics: processAdvancedMetrics(configuration: configuration, timestamp: timestamp)
        )
        let indexer = ProcessSnapshot(
            id: indexerIdentity, parentIdentity: nil, childIdentities: [],
            name: "Fixture Indexer", executablePath: "/Applications/Fixture Indexer.app/Contents/MacOS/Indexer",
            ownerUID: uid, isCurrentUser: true,
            cpuPercent: reading(3.2, .percent, timestamp),
            memoryBytes: reading(90_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(18_000, .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(4_000, .bytesPerSecond, timestamp),
            diskReadTotalBytes: reading(10_000_000, .bytes, timestamp),
            diskWriteTotalBytes: reading(2_000_000, .bytes, timestamp),
            advancedMetrics: processAdvancedMetrics(configuration: configuration, timestamp: timestamp)
        )

        let editorGroup = ProcessGroupSnapshot(
            id: editorIdentity, title: "Fixture Editor", ownerUID: uid,
            executablePath: editor.executablePath, association: .applicationBundle,
            historyIdentity: editorHistory, members: [editorIdentity, rendererIdentity],
            cpuPercent: reading(32, .percent, timestamp), memoryBytes: reading(600_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(326_000, .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(65_000, .bytesPerSecond, timestamp),
            networkReceiveBytesPerSecond: configuration.networkUnavailable
                ? unavailable(.bytesPerSecond, timestamp, .unsupported)
                : reading(14_500, .bytesPerSecond, timestamp),
            networkTransmitBytesPerSecond: configuration.networkUnavailable
                ? unavailable(.bytesPerSecond, timestamp, .unsupported)
                : reading(3_100, .bytesPerSecond, timestamp)
        )
        let indexerGroup = ProcessGroupSnapshot(
            id: indexerIdentity, title: configuration.duplicateGroups ? "Fixture Editor" : "Fixture Indexer", ownerUID: uid,
            executablePath: indexer.executablePath, association: .standalone,
            historyIdentity: indexerHistory, members: [indexerIdentity],
            cpuPercent: reading(3.2, .percent, timestamp), memoryBytes: reading(90_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(18_000, .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(4_000, .bytesPerSecond, timestamp),
            networkReceiveBytesPerSecond: reading(900, .bytesPerSecond, timestamp),
            networkTransmitBytesPerSecond: reading(200, .bytesPerSecond, timestamp)
        )

        let pressure: MemoryPressureLevel = sampleIndex % 18 == 0 ? .warning : .normal
        let system = SystemMetricsSnapshot(
            capacityCores: 8,
            cpuPercent: reading(36 + Double(sampleIndex % 5) * 3, .percent, timestamp),
            perCoreCPUPercent: (0..<8).map { index in
                reading(Double((sampleIndex * 11 + index * 13) % 90), .percent, timestamp)
            },
            memoryUsedBytes: reading(4_300_000_000, .bytes, timestamp),
            memoryAvailableBytes: reading(3_900_000_000, .bytes, timestamp),
            memoryTotalBytes: reading(8_200_000_000, .bytes, timestamp),
            memoryAppBytes: reading(2_600_000_000, .bytes, timestamp),
            memoryWiredBytes: reading(1_200_000_000, .bytes, timestamp),
            memoryCompressedBytes: reading(500_000_000, .bytes, timestamp),
            memoryCachedFilesBytes: reading(1_400_000_000, .bytes, timestamp),
            memoryPressure: MemoryPressureSnapshot(level: pressure, timestamp: timestamp),
            swapUsedBytes: reading(640_000_000 + Double(sampleIndex * 400_000), .bytes, timestamp),
            swapTotalBytes: reading(2_000_000_000, .bytes, timestamp),
            diskReadBytesPerSecond: reading(425_000 + Double(sampleIndex * 700), .bytesPerSecond, timestamp),
            diskWriteBytesPerSecond: reading(84_000 + Double(sampleIndex * 400), .bytesPerSecond, timestamp),
            networkReceiveBytesPerSecond: configuration.networkUnavailable
                ? unavailable(.bytesPerSecond, timestamp, .unsupported)
                : reading(18_000 + Double(sampleIndex * 300), .bytesPerSecond, timestamp),
            networkTransmitBytesPerSecond: configuration.networkUnavailable
                ? unavailable(.bytesPerSecond, timestamp, .unsupported)
                : reading(4_000 + Double(sampleIndex * 100), .bytesPerSecond, timestamp),
            networkInterfaces: [NetworkInterfaceSnapshot(
                name: "fixture0", isUp: true,
                receiveBytesPerSecond: reading(18_000, .bytesPerSecond, timestamp),
                transmitBytesPerSecond: reading(4_000, .bytesPerSecond, timestamp),
                receiveTotalBytes: reading(9_000_000, .bytes, timestamp),
                transmitTotalBytes: reading(3_000_000, .bytes, timestamp)
            )]
        )

        // History days are local midnights, as the history store keys them.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let nowDay = calendar.startOfDay(for: timestamp)
        let historyDay = calendar.date(byAdding: .day, value: -1, to: nowDay) ?? nowDay.addingTimeInterval(-86_400)
        let history = [DailyHistorySummary(dayStart: historyDay, cpuSeconds: 4_320,
                                           diskReadBytes: 300_000_000, diskWriteBytes: 64_000_000,
                                           networkReceiveBytes: 80_000_000, networkTransmitBytes: 18_000_000,
                                           sampleCount: 5_000, gaps: configuration.historyGap ? 1 : 0, counterResets: 0)]
        let applicationHistory = [
            ApplicationDailyHistorySummary(dayStart: historyDay, application: editorHistory,
                                           cpuSeconds: 108, diskReadBytes: 45_000_000,
                                           diskWriteBytes: 11_000_000, networkReceiveBytes: 12_000_000,
                                           networkTransmitBytes: 2_000_000, sampleCount: 400,
                                           gaps: configuration.historyGap ? 1 : 0, counterResets: 0),
            ApplicationDailyHistorySummary(dayStart: historyDay, application: indexerHistory,
                                           cpuSeconds: 18, diskReadBytes: 5_000_000,
                                           diskWriteBytes: 900_000, networkReceiveBytes: 300_000,
                                           networkTransmitBytes: 90_000, sampleCount: 400,
                                           gaps: 0, counterResets: 0)
        ]

        let incompleteReason = "Some startup locations could not be inspected."
        let coverageReasons = configuration.incompleteDiscovery ? [incompleteReason] : []
        let capabilities: [MetricKind: MetricAvailability] = [
            .processes: MetricAvailability(available: true),
            .totalCPU: MetricAvailability(available: true),
            .perCoreCPU: MetricAvailability(available: true),
            .physicalMemory: MetricAvailability(available: true),
            .memoryPressure: MetricAvailability(available: true),
            .swap: MetricAvailability(available: true),
            .diskThroughput: MetricAvailability(available: true),
            .networkThroughput: configuration.networkUnavailable
                ? MetricAvailability(available: false, reason: .unsupported, detail: "Fixture provider does not supply network readings.")
                : MetricAvailability(available: true),
            .gpu: configuration.gpuUnavailable
                ? MetricAvailability(available: false, reason: .unsupported, detail: "Fixture GPU provider is unsupported.")
                : MetricAvailability(available: true),
            .energy: configuration.energyUnavailable
                ? MetricAvailability(available: false, reason: .unsupported, detail: "Fixture energy provider is unsupported.")
                : MetricAvailability(available: true),
            .processNetwork: configuration.networkUnavailable
                ? MetricAvailability(available: false, reason: .unsupported, detail: "Per-process network data is unsupported in this fixture.")
                : MetricAvailability(available: true),
            .processGPUTime: MetricAvailability(available: false, reason: .unsupported, detail: "Per-process GPU time is unsupported in this fixture."),
            .history: MetricAvailability(available: true),
            .startupItems: configuration.incompleteDiscovery
                ? MetricAvailability(available: false, reason: .permissionDenied, detail: incompleteReason)
                : MetricAvailability(available: true),
            .services: configuration.incompleteDiscovery
                ? MetricAvailability(available: false, reason: .permissionDenied, detail: "Some service locations could not be inspected.")
                : MetricAvailability(available: true),
            .userSessions: MetricAvailability(available: true)
        ]

        let startupItems = [DiscoveredEntrySnapshot(
            id: "fixture-agent", kind: .launchAgent, name: "Fixture Helper Agent",
            path: "/tmp/MicrogravityFixture/FixtureAgent", ownerUID: uid, state: .loaded,
            detail: "Deterministic UI test fixture; no host item was inspected."
        )]
        let services = [DiscoveredEntrySnapshot(
            id: "fixture-service", kind: .service, name: "Fixture Service",
            path: "/tmp/MicrogravityFixture/FixtureService", ownerUID: uid, state: .running,
            detail: "Deterministic UI test fixture; no host service was inspected."
        )]
        let users = [UserSessionSnapshot(uid: uid, shortName: "fixture-user", isCurrentUser: true,
                                         loginSessions: ["console"])]
        let advanced: [MetricKind: MetricReading] = advancedSystemMetrics(configuration: configuration,
                                                                           timestamp: timestamp,
                                                                           sampleIndex: sampleIndex)

        return MonitoringSnapshot(
            timestamp: timestamp, system: system, processes: [editor, renderer, indexer],
            processGroups: [editorGroup, indexerGroup], startupItems: startupItems, services: services,
            users: users,
            discoveryCoverage: [
                "startupItems": DiscoveryCoverage(complete: !configuration.incompleteDiscovery,
                                                   reasons: coverageReasons),
                "services": DiscoveryCoverage(complete: !configuration.incompleteDiscovery,
                                               reasons: configuration.incompleteDiscovery
                                                ? ["Some service locations could not be inspected."] : []),
                "users": DiscoveryCoverage(complete: true)
            ],
            capabilities: capabilities,
            advancedMetrics: advanced,
            history: history,
            applicationHistory: applicationHistory
        )
    }

    private static func processAdvancedMetrics(configuration: FixtureConfiguration,
                                               timestamp: Date) -> [MetricKind: MetricReading] {
        guard !configuration.networkUnavailable else { return [:] }
        return [.processNetwork: reading(3_200, .bytesPerSecond, timestamp)]
    }

    private static func advancedSystemMetrics(configuration: FixtureConfiguration,
                                               timestamp: Date,
                                               sampleIndex: Int) -> [MetricKind: MetricReading] {
        var metrics: [MetricKind: MetricReading] = [:]
        if configuration.gpuUnavailable {
            metrics[.gpu] = unavailable(.percent, timestamp, .unsupported, "Fixture GPU provider is unsupported.")
        } else {
            metrics[.gpu] = reading(20 + Double(sampleIndex % 8) * 4, .percent, timestamp)
        }
        if configuration.energyUnavailable {
            metrics[.energy] = unavailable(.joules, timestamp, .unsupported, "Fixture energy provider is unsupported.")
        } else {
            metrics[.energy] = reading(1.4 + Double(sampleIndex % 5) * 0.1, .watts, timestamp)
        }
        return metrics
    }

    nonisolated static func identity(pid: Int32, offset: Int64) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: 1_700_000_000 + offset,
                                                               microseconds: Int32(offset * 10_000)))
    }

    private static func reading(_ value: Double, _ unit: MetricUnit, _ timestamp: Date) -> MetricReading {
        MetricReading(value: value, unit: unit, timestamp: timestamp)
    }

    private static func unavailable(_ unit: MetricUnit, _ timestamp: Date,
                                    _ reason: MetricUnavailableReason,
                                    _ detail: String? = nil) -> MetricReading {
        MetricReading(unavailable: unit, timestamp: timestamp, reason: reason, detail: detail)
    }
}

actor FixtureProcessActioner: ProcessActioning {
    private let configuration: FixtureConfiguration
    private let onSuccessfulTermination: (@MainActor @Sendable (ProcessIdentity) -> Void)?

    init(configuration: FixtureConfiguration,
         onSuccessfulTermination: (@MainActor @Sendable (ProcessIdentity) -> Void)? = nil) {
        self.configuration = configuration
        self.onSuccessfulTermination = onSuccessfulTermination
    }

    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        if configuration.successfulForceQuit {
            let expected = FixtureMonitoringStore.identity(pid: 411, offset: 2)
            guard force, identity == expected else {
                return ProcessActionResult(identity: identity, force: force,
                                           outcome: .rejected(.identityChanged,
                                                              detail: "Fixture action did not match its expected process identity."))
            }
            await onSuccessfulTermination?(identity)
            return ProcessActionResult(identity: identity, force: true, outcome: .signalSent)
        }
        let rejection: ProcessActionRejection = configuration.staleTarget ? .identityChanged : .helperUnavailable
        let detail = configuration.staleTarget ? nil : "Fixture mode never signals a host process."
        return ProcessActionResult(identity: identity, force: force,
                                   outcome: .rejected(rejection, detail: detail))
    }
}
#endif
