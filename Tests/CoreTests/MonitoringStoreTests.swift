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

    func testStopDuringHistoryRecordDoesNotPublishTheStaleSnapshot() async {
        let history = SuspendedRecordingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history)
        var callbacks = 0
        store.onSnapshot = { _ in callbacks += 1 }
        store.start(interval: .fiveSeconds)
        let refresh = Task { await store.refreshNow() }

        await history.waitForRecordStart()
        store.stop()
        await history.releaseRecord()
        await refresh.value

        XCTAssertNil(store.latestSnapshot)
        XCTAssertTrue(store.graphSamples.isEmpty)
        XCTAssertEqual(callbacks, 0)
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

    func testHistorySummaryReadsAreThrottledAndInvalidatedByDayAndReset() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15,
                                                       hour: 23, minute: 59, second: 50))!
        let clock = MutableTestClock(start)
        let history = CountingHistoryStore()
        let store = DefaultMonitoringStore(collector: StaticCollector(), historyStore: history,
                                           now: { clock.date })

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
