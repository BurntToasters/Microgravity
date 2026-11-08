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
    private var dayCalendar: HistoryDayCalendar
    private var pollingTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Error>?
    /// Background commit requested by pause() or stop(). Exposed so tests can await it.
    private(set) var historyFlushTask: Task<Void, Never>?
    private var isCollecting = false
    private var isResettingHistory = false
    /// Why the next history sample must not integrate across the previous one. Nil when no gap is pending.
    private var historyGapReason: MetricUnavailableReason?
    private var graphGapPending = false
    private var historySummaryCache: HistorySummaryCache?
    private var historySummaryQueryTimestamp: Date?
    private var historySummaryQueryDay: Date?
    private var historySummaryFailure: String?
    private var historyWriteFailure: String?
    private var publicationGeneration = 0

    public init(collector: any MonitoringCollecting,
                historyStore: (any MonitoringHistoryManaging)? = nil) {
        self.collector = collector
        self.historyStore = historyStore
        now = { Date() }
        dayCalendar = HistoryDayCalendar()
    }

    init(collector: any MonitoringCollecting,
         historyStore: (any MonitoringHistoryManaging)? = nil,
         now: @escaping @Sendable () -> Date,
         timeZone: TimeZone? = nil) {
        self.collector = collector
        self.historyStore = historyStore
        self.now = now
        dayCalendar = HistoryDayCalendar(timeZone: timeZone)
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
        historyGapReason = historyGapReason ?? .sleepGap
        graphGapPending = true
        publicationGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        scheduleHistoryFlush()
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
        scheduleHistoryFlush()
    }

    /// Commits buffered history totals now. A failure is reported like other history write failures.
    public func flushHistory() async {
        guard let historyStore else { return }
        do {
            try await historyStore.flush()
        } catch {
            historyWriteFailure = error.localizedDescription
            if let latestSnapshot { republish(withCachedHistory(latestSnapshot)) }
        }
    }

    private func scheduleHistoryFlush() {
        guard historyStore != nil else { return }
        historyFlushTask = Task { @MainActor [weak self] in
            await self?.flushHistory()
        }
    }

    public func refreshNow() async {
        guard !isPaused, !isCollecting, !isResettingHistory else { return }
        isCollecting = true
        defer { isCollecting = false }

        let generation = publicationGeneration
        let timestamp = now()
        let snapshot = await Task.detached(priority: .utility) { [collector] in
            await collector.collect(at: timestamp)
        }.value
        guard generation == publicationGeneration, !isPaused else { return }

        guard let historyStore else {
            historyGapReason = nil
            publish(snapshot)
            return
        }

        // Publish first so UI latency never includes the history transaction. The
        // published history fields come from the cache; a follow-up publication
        // applies the write result and any refreshed summaries.
        invalidateHistorySummaryCacheIfNeeded(through: timestamp)
        publish(withCachedHistory(snapshot))
        guard generation == publicationGeneration, !isPaused else { return }

        // Writes stay ordered: refreshNow is serialized by isCollecting and does not
        // return until its write settles, so at most one record is ever in flight.
        // The gap reason is read here, after any earlier write has settled.
        let historySnapshot = historyGapReason.map { snapshot.markingHistoryGap(reason: $0) } ?? snapshot
        let writeTask = Task { try await historyStore.record(snapshot: historySnapshot) }
        historyWriteTask = writeTask
        do {
            try await writeTask.value
        } catch {
            historyWriteTask = nil
            guard generation == publicationGeneration, !isPaused else { return }
            // A sample that failed to persist is a collection loss, not a sleep or pause.
            historyGapReason = .collectionFailed
            historyWriteFailure = error.localizedDescription
            republish(withCachedHistory(snapshot))
            return
        }
        historyWriteTask = nil
        guard generation == publicationGeneration, !isPaused else { return }
        historyGapReason = nil
        let clearedWriteFailure = historyWriteFailure != nil
        historyWriteFailure = nil

        var summariesChanged = false
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
            summariesChanged = true
        }
        if summariesChanged || clearedWriteFailure {
            republish(withCachedHistory(snapshot))
        }
    }

    /// Appends the graph sample and notifies observers. Used once per collected sample.
    private func publish(_ snapshot: MonitoringSnapshot) {
        latestSnapshot = snapshot
        graphSamples.append(MonitoringGraphSample(snapshot: graphGapPending
            ? snapshot.markingHistoryGap(markingAdvancedMetrics: true) : snapshot))
        if graphSamples.count > Self.maximumGraphSamples {
            graphSamples.removeFirst(graphSamples.count - Self.maximumGraphSamples)
        }
        if graphGapPending { graphGapPending = false }
        onSnapshot?(snapshot)
    }

    /// Re-notifies the current sample with updated history fields. Never adds a graph sample.
    private func republish(_ snapshot: MonitoringSnapshot) {
        latestSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private func withCachedHistory(_ snapshot: MonitoringSnapshot) -> MonitoringSnapshot {
        if let message = historyWriteFailure ?? historySummaryFailure {
            return snapshot.replacingHistoryFailure(message)
        }
        if let historySummaryCache {
            return snapshot.replacingHistory(historySummaryCache.summaries,
                                             applicationHistory: historySummaryCache.applicationSummaries)
        }
        return snapshot
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
        historyGapReason = historyGapReason ?? .sleepGap
        historySummaryCache = nil
        historySummaryQueryTimestamp = nil
        historySummaryQueryDay = nil
        historySummaryFailure = nil
        historyWriteFailure = nil
        guard let latestSnapshot else { return }
        let cleared = latestSnapshot.replacingHistory([], applicationHistory: [])
        self.latestSnapshot = cleared
        onSnapshot?(cleared)
    }

    private func schedulePolling() {
        pollingTask?.cancel()
        guard isRunning, !isPaused else { return }
        pollingTask = Task { @MainActor [weak self] in
            // Samples start on a fixed grid so collection time does not stretch the period.
            let clock = ContinuousClock()
            var nextSample = clock.now
            while let self, self.isRunning, !self.isPaused, !Task.isCancelled {
                await self.refreshNow()
                let period = Duration.seconds(self.interval.rawValue)
                nextSample = nextSample.advanced(by: period)
                let current = clock.now
                if nextSample <= current {
                    // Behind schedule: skip the missed ticks instead of bursting to catch up.
                    let missed = (current - nextSample) / period
                    nextSample = nextSample.advanced(by: period * (Int(missed) + 1))
                }
                do {
                    try await clock.sleep(until: nextSample)
                } catch {
                    break
                }
            }
        }
    }

    private func invalidateHistorySummaryCacheIfNeeded(through timestamp: Date) {
        let calendar = dayCalendar.current()
        let dayStart = HistoryDayCalendar.dayStart(containing: timestamp, in: calendar)
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

private extension MonitoringSnapshot {
    func markingHistoryGap(reason: MetricUnavailableReason = .sleepGap,
                           markingAdvancedMetrics: Bool = false) -> MonitoringSnapshot {
        func gap(_ reading: MetricReading) -> MetricReading {
            guard reading.isAvailable else { return reading }
            return MetricReading(unavailable: reading.unit, timestamp: reading.timestamp, reason: reason)
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
