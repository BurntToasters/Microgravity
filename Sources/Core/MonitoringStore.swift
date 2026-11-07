import Foundation

@MainActor
public final class DefaultMonitoringStore: MonitoringStore {
    public static let maximumGraphSamples = 720
    private static let historySummaryRefreshInterval: TimeInterval = 20

    private struct HistorySummaryCache {
        let summaries: [DailyHistorySummary]
        let applicationSummaries: [ApplicationDailyHistorySummary]
    }

    public private(set) var latestSnapshot: MonitoringSnapshot?
    public private(set) var graphSamples: [MonitoringGraphSample] = []
    public private(set) var interval: MonitoringInterval = .oneSecond
    public private(set) var isPaused = false
    public private(set) var isRunning = false
    public var onSnapshot: (@MainActor @Sendable (MonitoringSnapshot) -> Void)?

    private let collector: any MonitoringCollecting
    private let historyStore: (any MonitoringHistoryManaging)?
    private let now: @Sendable () -> Date
    private var pollingTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Error>?
    private var isCollecting = false
    private var isResettingHistory = false
    private var historyGapPending = false
    private var graphGapPending = false
    private var historySummaryCache: HistorySummaryCache?
    private var historySummaryQueryTimestamp: Date?
    private var historySummaryQueryDay: Date?
    private var historySummaryFailure: String?
    private var publicationGeneration = 0

    public init(collector: any MonitoringCollecting,
                historyStore: (any MonitoringHistoryManaging)? = nil) {
        self.collector = collector
        self.historyStore = historyStore
        now = { Date() }
    }

    init(collector: any MonitoringCollecting,
         historyStore: (any MonitoringHistoryManaging)? = nil,
         now: @escaping @Sendable () -> Date) {
        self.collector = collector
        self.historyStore = historyStore
        self.now = now
    }

    public func start(interval: MonitoringInterval = .oneSecond) {
        self.interval = interval
        isRunning = true
        isPaused = false
        schedulePolling()
    }

    public func setInterval(_ interval: MonitoringInterval) {
        guard self.interval != interval else { return }
        self.interval = interval
        if isRunning && !isPaused { schedulePolling() }
    }

    public func pause() {
        isPaused = true
        historyGapPending = true
        graphGapPending = true
        publicationGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if isRunning { schedulePolling() }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        publicationGeneration += 1
        isRunning = false
        isPaused = false
    }

    public func refreshNow() async {
        guard !isPaused, !isCollecting, !isResettingHistory else { return }
        isCollecting = true
        defer { isCollecting = false }

        let generation = publicationGeneration
        let marksHistoryGap = historyGapPending
        let timestamp = now()
        var snapshot = await Task.detached(priority: .utility) { [collector] in
            await collector.collect(at: timestamp)
        }.value
        guard generation == publicationGeneration, !isPaused else { return }

        if let historyStore {
            invalidateHistorySummaryCacheIfNeeded(through: timestamp)
            let historySnapshot = marksHistoryGap ? snapshot.markingHistoryGap() : snapshot
            let writeTask = Task { try await historyStore.record(snapshot: historySnapshot) }
            historyWriteTask = writeTask
            do {
                try await writeTask.value
                historyWriteTask = nil
                if generation == publicationGeneration { historyGapPending = false }
                guard generation == publicationGeneration, !isPaused else { return }
                if shouldRefreshHistorySummaries(at: timestamp) {
                    do {
                        async let systemHistory = historyStore.summaries(lastDays: 30, through: timestamp)
                        async let appHistory = historyStore.applicationSummaries(lastDays: 30, through: timestamp)
                        let summaries = try await systemHistory
                        let applicationSummaries = try await appHistory
                        guard generation == publicationGeneration, !isPaused else { return }
                        historySummaryQueryTimestamp = timestamp
                        historySummaryCache = HistorySummaryCache(summaries: summaries,
                                                                  applicationSummaries: applicationSummaries)
                        historySummaryFailure = nil
                    } catch {
                        guard generation == publicationGeneration, !isPaused else { return }
                        historySummaryQueryTimestamp = timestamp
                        historySummaryFailure = error.localizedDescription
                    }
                }
                if let historySummaryFailure {
                    snapshot = snapshot.replacingHistoryFailure(historySummaryFailure)
                } else if let historySummaryCache {
                    snapshot = snapshot.replacingHistory(historySummaryCache.summaries,
                                                         applicationHistory: historySummaryCache.applicationSummaries)
                }
            } catch {
                historyWriteTask = nil
                guard generation == publicationGeneration, !isPaused else { return }
                historyGapPending = true
                snapshot = snapshot.replacingHistoryFailure(error.localizedDescription)
            }
        }

        guard generation == publicationGeneration, !isPaused else { return }
        latestSnapshot = snapshot
        graphSamples.append(MonitoringGraphSample(snapshot: graphGapPending
            ? snapshot.markingHistoryGap(markingAdvancedMetrics: true) : snapshot))
        if graphSamples.count > Self.maximumGraphSamples {
            graphSamples.removeFirst(graphSamples.count - Self.maximumGraphSamples)
        }
        if graphGapPending { graphGapPending = false }
        if historyStore == nil { historyGapPending = false }
        onSnapshot?(snapshot)
    }

    public func resetHistory() async throws {
        guard let historyStore else {
            throw MonitoringHistoryError.databaseUnavailable("History storage is unavailable.")
        }
        isResettingHistory = true
        publicationGeneration += 1
        defer { isResettingHistory = false }
        if let historyWriteTask { try? await historyWriteTask.value }
        try await historyStore.reset()
        historyGapPending = true
        historySummaryCache = nil
        historySummaryQueryTimestamp = nil
        historySummaryQueryDay = nil
        historySummaryFailure = nil
        guard let latestSnapshot else { return }
        let cleared = latestSnapshot.replacingHistory([], applicationHistory: [])
        self.latestSnapshot = cleared
        onSnapshot?(cleared)
    }

    private func schedulePolling() {
        pollingTask?.cancel()
        guard isRunning, !isPaused else { return }
        pollingTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !self.isPaused, !Task.isCancelled {
                await self.refreshNow()
                let delay = UInt64(self.interval.rawValue * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
            }
        }
    }

    private func invalidateHistorySummaryCacheIfNeeded(through timestamp: Date) {
        let dayStart = utcDayStart(timestamp)
        guard historySummaryQueryDay != dayStart else { return }
        historySummaryCache = nil
        historySummaryQueryTimestamp = nil
        historySummaryFailure = nil
        historySummaryQueryDay = dayStart
    }

    private func shouldRefreshHistorySummaries(at timestamp: Date) -> Bool {
        guard let historySummaryQueryTimestamp else { return true }
        let elapsed = timestamp.timeIntervalSince(historySummaryQueryTimestamp)
        return elapsed < 0 || elapsed >= Self.historySummaryRefreshInterval
    }
}

@MainActor
public enum CoreMonitoring {
    public static func makeDefaultStore() -> DefaultMonitoringStore {
        let history = SQLiteMonitoringHistoryStore()
        return DefaultMonitoringStore(collector: SystemMonitorCollector(), historyStore: history)
    }
}

extension MonitoringStore {
    public func start() { start(interval: .oneSecond) }
}

private func utcDayStart(_ date: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.startOfDay(for: date)
}

private extension MonitoringSnapshot {
    func markingHistoryGap(markingAdvancedMetrics: Bool = false) -> MonitoringSnapshot {
        func gap(_ reading: MetricReading) -> MetricReading {
            guard reading.isAvailable else { return reading }
            return MetricReading(unavailable: reading.unit, timestamp: reading.timestamp, reason: .sleepGap)
        }
        let nextSystem = SystemMetricsSnapshot(
            capacityCores: system.capacityCores,
            cpuPercent: gap(system.cpuPercent),
            perCoreCPUPercent: system.perCoreCPUPercent.map(gap),
            memoryUsedBytes: system.memoryUsedBytes,
            memoryAvailableBytes: system.memoryAvailableBytes,
            memoryTotalBytes: system.memoryTotalBytes,
            memoryPressure: system.memoryPressure,
            swapUsedBytes: system.swapUsedBytes,
            swapTotalBytes: system.swapTotalBytes,
            diskReadBytesPerSecond: gap(system.diskReadBytesPerSecond),
            diskWriteBytesPerSecond: gap(system.diskWriteBytesPerSecond),
            networkReceiveBytesPerSecond: gap(system.networkReceiveBytesPerSecond),
            networkTransmitBytesPerSecond: gap(system.networkTransmitBytesPerSecond),
            networkInterfaces: system.networkInterfaces)
        let nextGroups = processGroups.map { group in
            ProcessGroupSnapshot(
                id: group.id, title: group.title, ownerUID: group.ownerUID,
                executablePath: group.executablePath, association: group.association,
                historyIdentity: group.historyIdentity, members: group.members,
                cpuPercent: gap(group.cpuPercent), memoryBytes: group.memoryBytes,
                diskReadBytesPerSecond: gap(group.diskReadBytesPerSecond),
                diskWriteBytesPerSecond: gap(group.diskWriteBytesPerSecond),
                networkReceiveBytesPerSecond: gap(group.networkReceiveBytesPerSecond),
                networkTransmitBytesPerSecond: gap(group.networkTransmitBytesPerSecond))
        }
        let nextAdvancedMetrics = markingAdvancedMetrics
            ? advancedMetrics.mapValues(gap) : advancedMetrics
        return MonitoringSnapshot(timestamp: timestamp, system: nextSystem, processes: processes,
                                  processGroups: nextGroups, startupItems: startupItems, services: services,
                                  users: users, discoveryCoverage: discoveryCoverage,
                                  capabilities: capabilities, advancedMetrics: nextAdvancedMetrics,
                                  history: history, applicationHistory: applicationHistory)
    }

    func replacingHistory(_ history: [DailyHistorySummary],
                          applicationHistory: [ApplicationDailyHistorySummary]) -> MonitoringSnapshot {
        var nextCapabilities = capabilities
        nextCapabilities[.history] = MetricAvailability(available: true)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: processes,
                                  processGroups: processGroups, startupItems: startupItems, services: services,
                                  users: users, discoveryCoverage: discoveryCoverage,
                                  capabilities: nextCapabilities, advancedMetrics: advancedMetrics,
                                  history: history, applicationHistory: applicationHistory)
    }

    func replacingHistoryFailure(_ message: String) -> MonitoringSnapshot {
        var nextCapabilities = capabilities
        nextCapabilities[.history] = MetricAvailability(available: false,
                                                         reason: .collectionFailed, detail: message)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: processes,
                                  processGroups: processGroups, startupItems: startupItems, services: services,
                                  users: users, discoveryCoverage: discoveryCoverage,
                                  capabilities: nextCapabilities, advancedMetrics: advancedMetrics,
                                  history: history, applicationHistory: applicationHistory)
    }
}
