import XCTest
@testable import Microgravity

@MainActor
final class MonitoringStoreTests: XCTestCase {
    func testRefreshNotifiesOnMainActorAndBoundsGraphSamples() async {
        let collector = StaticCollector()
        let store = DefaultMonitoringStore(collector: collector)
        var callbacks = 0
        store.onSnapshot = { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(snapshot.timestamp, store.latestSnapshot?.timestamp)
            callbacks += 1
        }

        for _ in 0..<(DefaultMonitoringStore.maximumGraphSamples + 5) {
            await store.refreshNow()
        }

        XCTAssertEqual(callbacks, DefaultMonitoringStore.maximumGraphSamples + 5)
        XCTAssertEqual(store.graphSamples.count, DefaultMonitoringStore.maximumGraphSamples)
        XCTAssertEqual(store.latestSnapshot?.timestamp, store.graphSamples.last?.timestamp)
    }

    func testPauseAndIntervalChangesUpdatePollingState() async {
        let store = DefaultMonitoringStore(collector: StaticCollector())

        store.start(interval: .fiveSeconds)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.interval, .fiveSeconds)

        store.setInterval(.halfSecond)
        XCTAssertEqual(store.interval, .halfSecond)
        store.pause()
        XCTAssertTrue(store.isPaused)
        let before = store.latestSnapshot
        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot, before, "pause suppresses even a direct refresh")

        store.resume()
        XCTAssertFalse(store.isPaused)
        await store.refreshNow()
        XCTAssertNotNil(store.latestSnapshot)
        store.stop()
        XCTAssertFalse(store.isRunning)
    }

    func testSnapshotPublishesBeforeHistoryWriteCompletes() async {
        let history = SuspendedRecordingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)
        var callbacks = 0
        store.onSnapshot = { _ in callbacks += 1 }
        let refresh = Task { await store.refreshNow() }

        await history.waitForRecordStart()
        XCTAssertEqual(callbacks, 1, "the UI must receive the sample while its history write is suspended")
        XCTAssertNotNil(store.latestSnapshot)
        XCTAssertEqual(store.graphSamples.count, 1)
        let rowsBeforeRelease = await history.rowCount()
        XCTAssertEqual(rowsBeforeRelease, 0)

        await history.releaseRecord()
        await refresh.value
        let rowsAfterWrite = await history.rowCount()
        XCTAssertEqual(rowsAfterWrite, 1)
    }

    func testPollingPeriodDoesNotDriftWithSlowCollector() async {
        // 0.3 s of collection per sample on a 0.5 s grid: five samples span four periods
        // (2.0 s). Sleeping one interval after each collection would take 3.2 s.
        let collector = TimingCollector(collectionDuration: .milliseconds(300))
        let store = DefaultMonitoringStore(collector: collector)
        store.start(interval: .halfSecond)

        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        var count = await collector.startCount()
        while count < 5, ContinuousClock.now < limit {
            try? await Task.sleep(nanoseconds: 10_000_000)
            count = await collector.startCount()
        }
        store.stop()

        let starts = await collector.startInstants
        XCTAssertGreaterThanOrEqual(starts.count, 5, "the polling loop must keep sampling")
        guard starts.count >= 5 else { return }
        let elapsed = seconds(starts[0].duration(to: starts[4]))
        XCTAssertGreaterThanOrEqual(elapsed, 1.9, "samples must not run early")
        XCTAssertLessThan(elapsed, 2.6, "collection time must not stretch the sampling period")
    }

    func testStopDuringHistoryRecordSuppressesTheHistoryFollowUp() async {
        let history = SuspendedRecordingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)
        var callbacks = 0
        store.onSnapshot = { _ in callbacks += 1 }
        let refresh = Task { await store.refreshNow() }

        await history.waitForRecordStart()
        XCTAssertEqual(callbacks, 1, "the live sample is published before the write")
        store.stop()
        await history.releaseRecord()
        await refresh.value

        XCTAssertEqual(callbacks, 1, "a stopped generation must not publish history results")
        XCTAssertEqual(store.graphSamples.count, 1)
    }

    func testHistoryResetFailureIsReturnedToTheCaller() async {
        let expected = HistoryTestError.storageUnavailable
        let history = FailingHistoryStore(error: expected)
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)

        do {
            try await store.resetHistory()
            XCTFail("The UI must be able to report history reset failure")
        } catch {
            XCTAssertEqual(error as? HistoryTestError, expected)
        }
    }

    func testPauseMarksTheFirstResumedHistorySampleAsAGap() async {
        let history = CapturingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)

        await store.refreshNow()
        store.pause()
        store.resume()
        await store.refreshNow()

        let recorded = await history.recordedSnapshots()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.last?.system.cpuPercent.unavailableReason, .sleepGap,
                       "history must not integrate a rate across a paused collection interval")
        XCTAssertEqual(store.graphSamples.last?.cpuPercent.unavailableReason, .sleepGap,
                       "the graph must show the pause boundary too")

        await store.refreshNow()
        let afterGap = await history.recordedSnapshots().last
        XCTAssertNotNil(afterGap?.system.cpuPercent.value,
                        "a committed gap must not remain pending on later samples")
    }

    func testFailedHistoryWriteEstablishesGapBeforeResumingIntegration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microgravity-history-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let history = FailOnSecondRecordHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = MutableTestClock(start)
        let store = DefaultMonitoringStore(collector: RateSequenceCollector([10, 100, 90, 20]),
                                           historyStore: history, now: { clock.date })

        await store.refreshNow()
        clock.advance(by: 1)
        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot?.capabilities[.history]?.reason, .collectionFailed)
        clock.advance(by: 1)
        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot?.system.cpuPercent.value, 90,
                       "the live reading remains available while its history interval is marked incomplete")
        clock.advance(by: 1)
        await store.refreshNow()

        let summary = try await history.summaries(lastDays: 30, through: clock.date).first
        XCTAssertEqual(summary?.sampleCount, 3, "the failed write is not committed")
        XCTAssertEqual(summary?.gaps, 1, "the recovery sample records the failed-write boundary")
        XCTAssertEqual(summary?.cpuSeconds ?? 0, 0.8, accuracy: 0.0001,
                       "only the post-recovery 20% sample may contribute one second of CPU")
        XCTAssertEqual(summary?.diskReadBytes, 20,
                       "the changing rates during the failed interval must not inflate history")
        XCTAssertEqual(summary?.diskWriteBytes, 20)
        XCTAssertEqual(summary?.networkReceiveBytes, 20)
        XCTAssertEqual(summary?.networkTransmitBytes, 20)
    }

    func testPauseGapAppearsInGraphWithoutHistoryStorageAndClearsAfterResume() async {
        let store = DefaultMonitoringStore(collector: StaticCollector())

        await store.refreshNow()
        store.pause()
        store.resume()
        await store.refreshNow()

        XCTAssertEqual(store.graphSamples.last?.cpuPercent.unavailableReason, .sleepGap)

        await store.refreshNow()
        XCTAssertNotNil(store.graphSamples.last?.cpuPercent.value,
                        "the graph gap should apply to the resumed sample only")
    }

    func testPauseGapMarksAvailableAdvancedGraphReadingsWithoutChangingLiveSnapshot() async {
        let gpu = AdvancedValue.available(42, .percent)
        let energy = AdvancedValue.available(12.5, .watts)
        let store = DefaultMonitoringStore(collector: AdvancedStaticCollector(gpu: gpu, energy: energy))

        await store.refreshNow()
        store.pause()
        store.resume()
        await store.refreshNow()

        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.gpu]?.unavailableReason, .sleepGap)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.energy]?.unavailableReason, .sleepGap)
        XCTAssertEqual(store.latestSnapshot?.advancedMetrics[.gpu]?.value, 42,
                       "the live snapshot must retain the collected GPU value")
        XCTAssertEqual(store.latestSnapshot?.advancedMetrics[.energy]?.value, 12.5,
                       "the live snapshot must retain the collected power value")

        await store.refreshNow()
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.gpu]?.value, 42)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.energy]?.value, 12.5,
                       "only the first resumed graph sample should be marked as a gap")
    }

    func testPauseGapMarksAdvancedGraphReadingsWithHistoryStorageOnly() async {
        let history = CapturingHistoryStore()
        let store = DefaultMonitoringStore(
            collector: AdvancedStaticCollector(gpu: .available(42, .percent), energy: .available(12.5, .watts)),
            historyStore: history)

        await store.refreshNow()
        store.pause()
        store.resume()
        await store.refreshNow()

        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.gpu]?.unavailableReason, .sleepGap)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.energy]?.unavailableReason, .sleepGap)
        let recorded = await history.recordedSnapshots()
        XCTAssertEqual(recorded.last?.system.cpuPercent.unavailableReason, .sleepGap)
        XCTAssertEqual(recorded.last?.advancedMetrics[.gpu]?.value, 42,
                       "history gap semantics for advanced readings remain unchanged")
        XCTAssertEqual(recorded.last?.advancedMetrics[.energy]?.value, 12.5)

        await store.refreshNow()
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.gpu]?.value, 42)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.energy]?.value, 12.5)
    }

    func testPauseGapPreservesReasonsForUnavailableAdvancedReadings() async {
        let store = DefaultMonitoringStore(collector: AdvancedStaticCollector(
            gpu: .unavailable(.percent, .permissionDenied),
            energy: .unavailable(.watts, .unsupported)))

        store.pause()
        store.resume()
        await store.refreshNow()

        XCTAssertNil(store.graphSamples.last?.advancedMetrics[.gpu]?.value)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.gpu]?.unavailableReason, .permissionDenied)
        XCTAssertNil(store.graphSamples.last?.advancedMetrics[.energy]?.value)
        XCTAssertEqual(store.graphSamples.last?.advancedMetrics[.energy]?.unavailableReason, .unsupported)
        XCTAssertEqual(store.latestSnapshot?.advancedMetrics[.gpu]?.unavailableReason, .permissionDenied)
        XCTAssertEqual(store.latestSnapshot?.advancedMetrics[.energy]?.unavailableReason, .unsupported)
    }

    func testHistorySummaryReadsAreThrottledAndInvalidatedByDayAndReset() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15,
                                                       hour: 23, minute: 59, second: 50))!
        let clock = MutableTestClock(start)
        let history = CountingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history,
                                           now: { clock.date }, timeZone: TimeZone(secondsFromGMT: 0))

        await store.refreshNow()
        clock.advance(by: 1)
        await store.refreshNow()
        var reads = await history.summaryReadCount()
        var applicationReads = await history.applicationSummaryReadCount()
        XCTAssertEqual(reads, 1, "the 30-day query should be reused within the throttle window")
        XCTAssertEqual(applicationReads, 1)

        clock.advance(by: 10)
        await store.refreshNow()
        reads = await history.summaryReadCount()
        applicationReads = await history.applicationSummaryReadCount()
        XCTAssertEqual(reads, 2, "UTC day rollover must invalidate the cached daily totals")
        XCTAssertEqual(applicationReads, 2)

        clock.advance(by: 1)
        await store.refreshNow()
        reads = await history.summaryReadCount()
        applicationReads = await history.applicationSummaryReadCount()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(applicationReads, 2)

        try await store.resetHistory()
        clock.advance(by: 1)
        await store.refreshNow()
        reads = await history.summaryReadCount()
        applicationReads = await history.applicationSummaryReadCount()
        XCTAssertEqual(reads, 3, "reset must force an immediate summary refresh")
        XCTAssertEqual(applicationReads, 3)

        clock.advance(by: 21)
        await store.refreshNow()
        reads = await history.summaryReadCount()
        applicationReads = await history.applicationSummaryReadCount()
        XCTAssertEqual(reads, 4, "summary data should refresh after the throttle interval")
        XCTAssertEqual(applicationReads, 4)
    }

    func testPauseAndExplicitFlushCommitBufferedHistory() async {
        let history = FlushCountingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)

        await store.refreshNow()
        store.pause()
        await store.historyFlushTask?.value
        var flushes = await history.flushCount()
        XCTAssertEqual(flushes, 1, "pausing must commit the buffered history")

        await store.flushHistory()
        flushes = await history.flushCount()
        XCTAssertEqual(flushes, 2, "an explicit flush must reach the history store")
    }

    func testHistorySummaryFailureRemainsVisibleUntilTheNextRetry() async {
        let clock = MutableTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let history = CountingHistoryStore(shouldFailReads: true)
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history,
                                           now: { clock.date })

        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot?.capabilities[.history]?.reason, .collectionFailed)

        clock.advance(by: 1)
        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot?.capabilities[.history]?.reason, .collectionFailed,
                       "a cached failure must remain visible while its retry is throttled")
        var reads = await history.summaryReadCount()
        XCTAssertEqual(reads, 1)

        await history.setShouldFailReads(false)
        clock.advance(by: 20)
        await store.refreshNow()
        XCTAssertEqual(store.latestSnapshot?.capabilities[.history]?.available, true)
        reads = await history.summaryReadCount()
        XCTAssertEqual(reads, 2)
    }

    func testResetSerializesAfterAnInFlightHistoryRecord() async throws {
        let history = SuspendedRecordingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)
        let refresh = Task { await store.refreshNow() }

        await history.waitForRecordStart()
        let reset = Task { try await store.resetHistory() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let resetCompletedBeforeWrite = await history.didReset()
        XCTAssertFalse(resetCompletedBeforeWrite, "reset must wait for the in-flight write")
        await history.releaseRecord()

        await refresh.value
        try await reset.value
        let rowsAfterReset = await history.rowCount()
        XCTAssertEqual(rowsAfterReset, 0,
                       "the write that started before reset must not repopulate history afterward")
    }
}

private actor StaticCollector: MonitoringCollecting {
    func collect(at timestamp: Date) async -> MonitoringSnapshot {
        CoreTestFixtures.snapshot(timestamp: timestamp)
    }
}

private enum AdvancedValue: Sendable {
    case available(Double, MetricUnit)
    case unavailable(MetricUnit, MetricUnavailableReason)

    func reading(at timestamp: Date) -> MetricReading {
        switch self {
        case let .available(value, unit): MetricReading(value: value, unit: unit, timestamp: timestamp)
        case let .unavailable(unit, reason): MetricReading(unavailable: unit, timestamp: timestamp, reason: reason)
        }
    }
}

private actor AdvancedStaticCollector: MonitoringCollecting {
    private let gpu: AdvancedValue
    private let energy: AdvancedValue

    init(gpu: AdvancedValue, energy: AdvancedValue) {
        self.gpu = gpu
        self.energy = energy
    }

    func collect(at timestamp: Date) async -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        return MonitoringSnapshot(timestamp: timestamp, system: base.system, processes: base.processes,
                                  processGroups: base.processGroups, startupItems: base.startupItems,
                                  services: base.services, users: base.users,
                                  discoveryCoverage: base.discoveryCoverage, capabilities: base.capabilities,
                                  advancedMetrics: [.gpu: gpu.reading(at: timestamp),
                                                    .energy: energy.reading(at: timestamp)])
    }
}

private actor RateSequenceCollector: MonitoringCollecting {
    private let rates: [Double]
    private var index = 0

    init(_ rates: [Double]) { self.rates = rates }

    func collect(at timestamp: Date) async -> MonitoringSnapshot {
        let rate = rates[min(index, rates.count - 1)]
        index += 1
        return CoreTestFixtures.snapshot(timestamp: timestamp, cpuPercent: rate,
                                         diskReadRate: rate, diskWriteRate: rate,
                                         networkReceiveRate: rate, networkTransmitRate: rate)
    }
}

private actor TimingCollector: MonitoringCollecting {
    private let collectionDuration: Duration
    private(set) var startInstants: [ContinuousClock.Instant] = []

    init(collectionDuration: Duration) { self.collectionDuration = collectionDuration }

    func collect(at timestamp: Date) async -> MonitoringSnapshot {
        startInstants.append(ContinuousClock.now)
        try? await Task.sleep(for: collectionDuration)
        return CoreTestFixtures.snapshot(timestamp: timestamp)
    }

    func startCount() -> Int { startInstants.count }
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private enum HistoryTestError: Error, Equatable {
    case storageUnavailable
}

private actor FailingHistoryStore: MonitoringHistoryManaging {
    let error: HistoryTestError

    init(error: HistoryTestError) { self.error = error }

    func record(snapshot: MonitoringSnapshot) async throws {}
    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] { [] }
    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] { [] }
    func reset() async throws { throw error }
}

private actor CapturingHistoryStore: MonitoringHistoryManaging {
    private var snapshots: [MonitoringSnapshot] = []

    func record(snapshot: MonitoringSnapshot) async throws { snapshots.append(snapshot) }
    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] { [] }
    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] { [] }
    func reset() async throws { snapshots.removeAll() }
    func recordedSnapshots() -> [MonitoringSnapshot] { snapshots }
}

private actor FlushCountingHistoryStore: MonitoringHistoryManaging {
    private var flushes = 0

    func record(snapshot: MonitoringSnapshot) async throws {}
    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] { [] }
    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] { [] }
    func reset() async throws {}
    func flush() async throws { flushes += 1 }
    func flushCount() -> Int { flushes }
}

private actor CountingHistoryStore: MonitoringHistoryManaging {
    private var summariesReads = 0
    private var applicationSummaryReads = 0
    private var shouldFailReads: Bool

    init(shouldFailReads: Bool = false) {
        self.shouldFailReads = shouldFailReads
    }

    func record(snapshot: MonitoringSnapshot) async throws {}

    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] {
        summariesReads += 1
        if shouldFailReads { throw HistoryTestError.storageUnavailable }
        return []
    }

    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] {
        applicationSummaryReads += 1
        if shouldFailReads { throw HistoryTestError.storageUnavailable }
        return []
    }

    func reset() async throws {}

    func summaryReadCount() -> Int { summariesReads }
    func applicationSummaryReadCount() -> Int { applicationSummaryReads }
    func setShouldFailReads(_ shouldFail: Bool) { shouldFailReads = shouldFail }
}

private actor FailOnSecondRecordHistoryStore: MonitoringHistoryManaging {
    private let store: SQLiteMonitoringHistoryStore
    private var recordAttempts = 0

    init(databaseURL: URL) {
        store = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
    }

    func record(snapshot: MonitoringSnapshot) async throws {
        recordAttempts += 1
        if recordAttempts == 2 { throw HistoryTestError.storageUnavailable }
        try await store.record(snapshot: snapshot)
    }

    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] {
        try await store.summaries(lastDays: lastDays, through: date)
    }

    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] {
        try await store.applicationSummaries(lastDays: lastDays, through: date)
    }

    func reset() async throws { try await store.reset() }
}

private final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

private actor SuspendedRecordingHistoryStore: MonitoringHistoryManaging {
    private var rows = 0
    private var resetCompleted = false
    private var recordStartWaiter: CheckedContinuation<Void, Never>?
    private var recordReleaseWaiter: CheckedContinuation<Void, Never>?

    func record(snapshot: MonitoringSnapshot) async throws {
        recordStartWaiter?.resume()
        recordStartWaiter = nil
        await withCheckedContinuation { recordReleaseWaiter = $0 }
        rows += 1
    }

    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] { [] }
    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] { [] }

    func reset() async throws {
        rows = 0
        resetCompleted = true
    }

    func waitForRecordStart() async {
        if recordReleaseWaiter != nil { return }
        await withCheckedContinuation { recordStartWaiter = $0 }
    }

    func releaseRecord() {
        recordReleaseWaiter?.resume()
        recordReleaseWaiter = nil
    }

    func didReset() -> Bool { resetCompleted }
    func rowCount() -> Int { rows }
}
