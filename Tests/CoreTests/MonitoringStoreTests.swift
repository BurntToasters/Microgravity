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
