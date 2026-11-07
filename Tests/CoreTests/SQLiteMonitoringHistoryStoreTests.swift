import XCTest
import Darwin
import SQLite3
@testable import Microgravity

final class SQLiteMonitoringHistoryStoreTests: XCTestCase {
    func testPersistsDailyTotalsAndExplicitGapResetCounts() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                      cpuPercent: 50, diskReadRate: 100,
                                                                      diskWriteRate: 10, networkReceiveRate: 20,
                                                                      networkTransmitRate: 30))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(2),
                                                                      cpuReason: .sleepGap))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(3),
                                                                      cpuReason: .counterReset))

        let firstRead = try await history.summaries(lastDays: 30, through: start.addingTimeInterval(3)).first

        XCTAssertNotNil(firstRead)
        XCTAssertEqual(firstRead?.sampleCount, 4)
        XCTAssertEqual(firstRead?.cpuSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(firstRead?.diskReadBytes, 100)
        XCTAssertEqual(firstRead?.diskWriteBytes, 10)
        XCTAssertEqual(firstRead?.networkReceiveBytes, 20)
        XCTAssertEqual(firstRead?.networkTransmitBytes, 30)
        XCTAssertEqual(firstRead?.gaps, 1)
        XCTAssertEqual(firstRead?.counterResets, 1)

        // Reopening proves the history is persistent, not held only in process memory.
        let reopened = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let persisted = try await reopened.summaries(lastDays: 30, through: start.addingTimeInterval(3)).first
        XCTAssertEqual(persisted, firstRead)
    }

    func testRelaunchRecordsAGapWithoutBridgingTheClosedInterval() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSession = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)

        try await firstSession.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await firstSession.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                          cpuPercent: 50))
        let beforeRelaunch = try await firstSession.summaries(lastDays: 30,
                                                              through: start.addingTimeInterval(1)).first

        let relaunched = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        try await relaunched.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(2),
                                                                         cpuPercent: 90))
        let afterRelaunch = try await relaunched.summaries(lastDays: 30,
                                                           through: start.addingTimeInterval(2)).first

        XCTAssertEqual(afterRelaunch?.cpuSeconds, beforeRelaunch?.cpuSeconds,
                       "a fresh monitoring session must not integrate counters across process relaunch")
        XCTAssertEqual(afterRelaunch?.gaps, (beforeRelaunch?.gaps ?? 0) + 1,
                       "the persisted collection boundary must expose the relaunch gap")
    }

    func testInMemoryBaselineReloadsAfterAnotherStoreCommits() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let first = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let second = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 952, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let group = appGroup(id: "bundle:com.example.shared|/Applications/Shared.app",
                             name: "Shared", process: process)

        try await first.record(snapshot: snapshotWithGroups([group], at: start, cpuPercent: 50))
        try await second.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(1), cpuPercent: 50))
        try await first.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(2), cpuPercent: 50))
        try await first.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(3), cpuPercent: 50))

        let systemSummary = try await first.summaries(lastDays: 30,
                                                      through: start.addingTimeInterval(3)).first
        let applicationSummary = try await first.applicationSummaries(lastDays: 30,
                                                                      through: start.addingTimeInterval(3)).first
        XCTAssertEqual(systemSummary?.cpuSeconds ?? 0, 2, accuracy: 0.0001,
                       "samples from a different store session must not be integrated into this session")
        XCTAssertEqual(applicationSummary?.cpuSeconds ?? 0, 2, accuracy: 0.0001,
                       "application baselines must reload with the shared collection state")
    }

    func testApplicationBaselineChangesOnlyAfterTransactionCommits() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 951, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let group = appGroup(id: "bundle:com.example.commit|/Applications/Editor.app",
                             name: "Editor", process: process)

        try await history.record(snapshot: snapshotWithGroups([group], at: start))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let trigger = """
        CREATE TRIGGER reject_collection_state BEFORE INSERT ON monitoring_state
        BEGIN SELECT RAISE(ABORT, 'injected state failure'); END;
        """
        XCTAssertEqual(sqlite3_exec(database, trigger, nil, nil, nil), SQLITE_OK,
                       "schema must persist collection state transactionally")
        sqlite3_close(database)

        let measuredInterval = DateInterval(start: start, end: start.addingTimeInterval(1))
        let measuredGroup = appGroup(id: "bundle:com.example.commit|/Applications/Editor.app",
                                     name: "Editor", process: process, at: start.addingTimeInterval(1),
                                     networkReceiveRate: 20, networkReceiveInterval: measuredInterval)
        do {
            try await history.record(snapshot: snapshotWithGroups([measuredGroup],
                at: start.addingTimeInterval(1), networkReceiveRate: 20,
                networkReceiveInterval: measuredInterval))
            XCTFail("injected transaction failure must reach the caller")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_collection_state", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let retryGroup = appGroup(id: "bundle:com.example.commit|/Applications/Editor.app",
                                  name: "Editor", process: process, at: start.addingTimeInterval(2),
                                  networkReceiveRate: 20, networkReceiveInterval: measuredInterval)
        try await history.record(snapshot: snapshotWithGroups([retryGroup], at: start.addingTimeInterval(2),
            networkReceiveRate: 20, networkReceiveInterval: measuredInterval))
        let summary = try await history.applicationSummaries(lastDays: 30,
                                                             through: start.addingTimeInterval(2)).first
        let systemSummary = try await history.summaries(lastDays: 30,
                                                        through: start.addingTimeInterval(2)).first
        XCTAssertEqual(summary?.cpuSeconds ?? 0, 4, accuracy: 0.0001,
                       "the committed t0 baseline must survive the failed t1 transaction")
        XCTAssertEqual(summary?.networkReceiveBytes, 20,
                       "the failed transaction must not leave a measurement identity behind")
        XCTAssertEqual(systemSummary?.networkReceiveBytes, 20)
    }

    func testSystemAndApplicationIntervalsSplitAtUTCMidnight() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(86_400)
        let start = midnight.addingTimeInterval(-1)
        let end = midnight.addingTimeInterval(1)
        let process = ProcessIdentity(pid: 953, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.midnight|/Applications/Midnight.app"
        let firstGroup = appGroup(id: appID, name: "Midnight", process: process, at: start,
                                  cpuPercent: 25, diskReadRate: 100.75, diskWriteRate: 100,
                                  networkReceiveRate: 100)
        let secondGroup = appGroup(id: appID, name: "Midnight", process: process, at: end,
                                   cpuPercent: 25, diskReadRate: 100.75, diskWriteRate: 100,
                                   networkReceiveRate: 100,
                                   networkReceiveInterval: DateInterval(start: start, end: end),
                                   diskReadIsPartial: true,
                                   networkTransmitReason: .counterReset)

        try await history.record(snapshot: snapshotWithGroups([firstGroup], at: start,
            cpuPercent: 50, diskReadRate: 100.75, diskWriteRate: 100,
            networkReceiveRate: 100, networkTransmitRate: 100))
        try await history.record(snapshot: snapshotWithGroups([secondGroup], at: end,
            cpuPercent: 50, diskReadRate: 100.75, diskWriteRate: 100,
            networkReceiveRate: 100, networkTransmitRate: 100, diskReadIsPartial: true,
            networkReceiveInterval: DateInterval(start: start, end: end),
            networkTransmitReason: .counterReset))

        let systemSummaries = try await history.summaries(lastDays: 30, through: end)
        let appSummaries = try await history.applicationSummaries(lastDays: 30, through: end)
        XCTAssertEqual(systemSummaries.map(\.dayStart), [midnight.addingTimeInterval(-86_400), midnight])
        XCTAssertEqual(systemSummaries.map(\.sampleCount), [1, 1],
                       "the earlier interval segment must not count the endpoint sample twice")
        XCTAssertEqual(systemSummaries[0].cpuSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(systemSummaries[1].cpuSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(systemSummaries[0].diskReadBytes, 100)
        XCTAssertEqual(systemSummaries[1].diskReadBytes, 101,
                       "the endpoint day receives the remainder after whole-interval flooring")
        XCTAssertEqual(systemSummaries[0].diskWriteBytes, 100)
        XCTAssertEqual(systemSummaries[1].diskWriteBytes, 100)
        XCTAssertEqual(systemSummaries[0].networkReceiveBytes, 100)
        XCTAssertEqual(systemSummaries[1].networkReceiveBytes, 100)
        XCTAssertEqual(systemSummaries.map(\.gaps), [0, 1])
        XCTAssertEqual(systemSummaries.map(\.counterResets), [0, 1])

        XCTAssertEqual(appSummaries.map(\.dayStart), [midnight.addingTimeInterval(-86_400), midnight])
        XCTAssertEqual(appSummaries.map(\.sampleCount), [1, 1])
        XCTAssertEqual(appSummaries[0].cpuSeconds ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(appSummaries[1].cpuSeconds ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(appSummaries[0].diskReadBytes, 100)
        XCTAssertEqual(appSummaries[1].diskReadBytes, 101)
        XCTAssertEqual(appSummaries[0].diskWriteBytes, 100)
        XCTAssertEqual(appSummaries[1].diskWriteBytes, 100)
        XCTAssertEqual(appSummaries[0].networkReceiveBytes, 100)
        XCTAssertEqual(appSummaries[1].networkReceiveBytes, 100)
        XCTAssertEqual(appSummaries.map(\.gaps), [0, 1])
        XCTAssertEqual(appSummaries.map(\.counterResets), [0, 1])
    }

    func testApplicationPartialAggregateStoresLowerBoundAndCountsGap() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = "bundle:com.example.partial|/Applications/Partial.app"
        let first = ProcessIdentity(pid: 954, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                microseconds: 0))
        let second = ProcessIdentity(pid: 955, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let initialGroups = [
            appGroup(id: id, name: "Partial", process: first, at: start, networkReceiveRate: 100),
            appGroup(id: id, name: "Partial", process: second, at: start, networkReceiveRate: 0),
        ]
        let partialGroups = [
            appGroup(id: id, name: "Partial", process: first, at: start.addingTimeInterval(1),
                     networkReceiveRate: 100,
                     networkReceiveInterval: DateInterval(start: start, end: start.addingTimeInterval(1))),
            appGroup(id: id, name: "Partial", process: second, at: start.addingTimeInterval(1),
                     networkReceiveReason: .unsupported),
        ]

        try await history.record(snapshot: snapshotWithGroups(initialGroups, at: start))
        try await history.record(snapshot: snapshotWithGroups(partialGroups, at: start.addingTimeInterval(1)))

        let summary = try await history.applicationSummaries(lastDays: 30,
                                                             through: start.addingTimeInterval(1)).first
        XCTAssertEqual(summary?.networkReceiveBytes, 100,
                       "the available contributor remains a measured lower bound")
        XCTAssertEqual(summary?.sampleCount, 2)
        XCTAssertEqual(summary?.gaps, 1, "the partial aggregate marks its day as incomplete")
    }

    func testCachedNetworkMeasurementIsCountedOnceForSystemAndApplication() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(5)
        let interval = DateInterval(start: start, end: end)
        let process = ProcessIdentity(pid: 957, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.cached|/Applications/Cached.app"

        try await history.record(snapshot: snapshotWithGroups([
            appGroup(id: appID, name: "Cached", process: process, at: start),
        ], at: start))
        for timestamp in [end, end.addingTimeInterval(1), end.addingTimeInterval(2)] {
            let group = appGroup(id: appID, name: "Cached", process: process, at: timestamp,
                                 networkReceiveRate: 20, networkTransmitRate: 10,
                                 networkReceiveInterval: interval, networkTransmitInterval: interval)
            try await history.record(snapshot: snapshotWithGroups([group], at: timestamp,
                networkReceiveRate: 20, networkTransmitRate: 10,
                networkReceiveInterval: interval, networkTransmitInterval: interval))
        }
        let nextEnd = end.addingTimeInterval(5)
        let nextInterval = DateInterval(start: end, end: nextEnd)
        let nextGroup = appGroup(id: appID, name: "Cached", process: process, at: nextEnd,
                                 networkReceiveRate: 40, networkTransmitRate: 20,
                                 networkReceiveInterval: nextInterval, networkTransmitInterval: nextInterval)
        try await history.record(snapshot: snapshotWithGroups([nextGroup], at: nextEnd,
            networkReceiveRate: 40, networkTransmitRate: 20,
            networkReceiveInterval: nextInterval, networkTransmitInterval: nextInterval))

        let system = try await history.summaries(lastDays: 30, through: nextEnd).first
        let application = try await history.applicationSummaries(lastDays: 30,
                                                                 through: nextEnd).first
        XCTAssertEqual(system?.networkReceiveBytes, 300,
                       "the next capture contributes its full five-second interval after cached repeats")
        XCTAssertEqual(application?.networkReceiveBytes, 300)
        XCTAssertEqual(system?.networkTransmitBytes, 150,
                       "transmit has an independent measurement identity from receive")
        XCTAssertEqual(application?.networkTransmitBytes, 150,
                       "application streams have independent identities from system streams")
        XCTAssertEqual(system?.sampleCount, 5)
        XCTAssertEqual(application?.sampleCount, 5)
    }

    func testReopenedHistoryDoesNotReplayPersistedNetworkMeasurement() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(5)
        let interval = DateInterval(start: start, end: end)
        let process = ProcessIdentity(pid: 959, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.persisted|/Applications/Persisted.app"
        let initial = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        try await initial.record(snapshot: snapshotWithGroups([
            appGroup(id: appID, name: "Persisted", process: process, at: start),
        ], at: start))
        let measuredGroup = appGroup(id: appID, name: "Persisted", process: process, at: end,
                                     networkReceiveRate: 20, networkReceiveInterval: interval)
        try await initial.record(snapshot: snapshotWithGroups([measuredGroup], at: end,
            networkReceiveRate: 20, networkReceiveInterval: interval))
        let beforeRestart = try await initial.summaries(lastDays: 30, through: end).first
        let appBeforeRestart = try await initial.applicationSummaries(lastDays: 30, through: end).first

        let reopened = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let cachedGroup = appGroup(id: appID, name: "Persisted", process: process,
                                   at: end.addingTimeInterval(1), networkReceiveRate: 20,
                                   networkReceiveInterval: interval)
        try await reopened.record(snapshot: snapshotWithGroups([cachedGroup], at: end.addingTimeInterval(1),
            networkReceiveRate: 20, networkReceiveInterval: interval))

        let afterRestart = try await reopened.summaries(lastDays: 30, through: end.addingTimeInterval(1)).first
        let appAfterRestart = try await reopened.applicationSummaries(lastDays: 30,
            through: end.addingTimeInterval(1)).first
        XCTAssertEqual(afterRestart?.networkReceiveBytes, beforeRestart?.networkReceiveBytes)
        XCTAssertEqual(appAfterRestart?.networkReceiveBytes, appBeforeRestart?.networkReceiveBytes)
        XCTAssertEqual(afterRestart?.gaps, (beforeRestart?.gaps ?? 0) + 1)
        XCTAssertEqual(appAfterRestart?.gaps, (appBeforeRestart?.gaps ?? 0) + 1)
    }

    func testDelayedNetworkMeasurementDoesNotDependOnSnapshotTimestamp() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 960, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.delayed|/Applications/Delayed.app"

        for offset in [0.0, 2.0] {
            let timestamp = start.addingTimeInterval(offset)
            let group = appGroup(id: appID, name: "Delayed", process: process, at: timestamp)
            try await history.record(snapshot: snapshotWithGroups([group], at: timestamp))
        }

        let measured = DateInterval(start: start, end: start.addingTimeInterval(1.5))
        let timestamp = start.addingTimeInterval(3)
        let group = appGroup(id: appID, name: "Delayed", process: process, at: timestamp,
                             networkReceiveRate: 20, networkReceiveInterval: measured)
        try await history.record(snapshot: snapshotWithGroups([group], at: timestamp,
            networkReceiveRate: 20, networkReceiveInterval: measured))

        let system = try await history.summaries(lastDays: 1, through: timestamp).first
        let application = try await history.applicationSummaries(lastDays: 1, through: timestamp).first
        XCTAssertEqual(system?.networkReceiveBytes, 30)
        XCTAssertEqual(application?.networkReceiveBytes, 30)
        XCTAssertEqual(application?.gaps, 0)
    }

    func testClockRollbackSuppressesCachedWindowsAndAcceptsFreshLowerWindow() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 961, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.rollback|/Applications/Rollback.app"
        let initial = appGroup(id: appID, name: "Rollback", process: process, at: start)
        try await history.record(snapshot: snapshotWithGroups([initial], at: start))

        let cached = DateInterval(start: start, end: start.addingTimeInterval(5))
        for offset in [5.0, 4.0, 4.5] {
            let timestamp = start.addingTimeInterval(offset)
            let group = appGroup(id: appID, name: "Rollback", process: process, at: timestamp,
                                 networkReceiveRate: 20, networkReceiveInterval: cached)
            try await history.record(snapshot: snapshotWithGroups([group], at: timestamp,
                networkReceiveRate: 20, networkReceiveInterval: cached))
        }

        let freshLowerWindow = DateInterval(start: start.addingTimeInterval(-5),
                                            end: start.addingTimeInterval(-4))
        let rollbackTimestamp = start.addingTimeInterval(-3)
        let rollbackGroup = appGroup(id: appID, name: "Rollback", process: process,
                                     at: rollbackTimestamp, networkReceiveRate: 30,
                                     networkReceiveInterval: freshLowerWindow)
        try await history.record(snapshot: snapshotWithGroups([rollbackGroup], at: rollbackTimestamp,
            networkReceiveRate: 30, networkReceiveInterval: freshLowerWindow))

        let system = try await history.summaries(lastDays: 1, through: start.addingTimeInterval(5)).first
        let application = try await history.applicationSummaries(lastDays: 1,
            through: start.addingTimeInterval(5)).first
        XCTAssertEqual(system?.networkReceiveBytes, 130)
        XCTAssertEqual(application?.networkReceiveBytes, 130)
    }

    func testNetworkMeasurementIdentityStateIsBoundedPerStreamAndResetClearsIt() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 962, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.bounded|/Applications/Bounded.app"
        let initial = appGroup(id: appID, name: "Bounded", process: process, at: start)
        try await history.record(snapshot: snapshotWithGroups([initial], at: start))

        for offset in 0..<SQLiteMonitoringHistoryStore.maximumRememberedMeasurementIntervalsPerStream + 5 {
            let measuredStart = start.addingTimeInterval(Double(offset))
            let measuredEnd = measuredStart.addingTimeInterval(1)
            let interval = DateInterval(start: measuredStart, end: measuredEnd)
            let group = appGroup(id: appID, name: "Bounded", process: process, at: measuredEnd,
                                 networkReceiveRate: 1, networkReceiveInterval: interval)
            try await history.record(snapshot: snapshotWithGroups([group], at: measuredEnd,
                networkReceiveRate: 1, networkReceiveInterval: interval))
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database,
            "SELECT scope, application_id, direction, COUNT(*) FROM network_measurement_state " +
            "GROUP BY scope, application_id, direction", -1, &statement, nil), SQLITE_OK)
        var streamCounts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let scope = String(cString: sqlite3_column_text(statement, 0))
            let applicationID = String(cString: sqlite3_column_text(statement, 1))
            let direction = String(cString: sqlite3_column_text(statement, 2))
            let count = Int(sqlite3_column_int64(statement, 3))
            streamCounts["\(scope):\(applicationID):\(direction)"] = count
        }
        sqlite3_finalize(statement)
        sqlite3_close(database)
        XCTAssertEqual(streamCounts["system::receive"],
                       SQLiteMonitoringHistoryStore.maximumRememberedMeasurementIntervalsPerStream)
        XCTAssertEqual(streamCounts["application:\(appID):receive"],
                       SQLiteMonitoringHistoryStore.maximumRememberedMeasurementIntervalsPerStream)

        try await history.reset()
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(database,
            "SELECT COUNT(*) FROM network_measurement_state", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 0)
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    func testPreResetNetworkMeasurementIsNotRecountedAfterResetOrReopen() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let base = Date().addingTimeInterval(-60)
        let process = ProcessIdentity(pid: 963, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.resetboundary|/Applications/ResetBoundary.app"
        let preResetInterval = DateInterval(start: base, end: base.addingTimeInterval(5))
        let preResetEnd = preResetInterval.end

        try await history.record(snapshot: snapshotWithGroups([
            appGroup(id: appID, name: "ResetBoundary", process: process, at: base),
        ], at: base))
        let measured = appGroup(id: appID, name: "ResetBoundary", process: process, at: preResetEnd,
                                networkReceiveRate: 100, networkReceiveInterval: preResetInterval)
        try await history.record(snapshot: snapshotWithGroups([measured], at: preResetEnd,
            networkReceiveRate: 100, networkReceiveInterval: preResetInterval))
        let beforeReset = try await history.summaries(lastDays: 30, through: preResetEnd).first
        XCTAssertEqual(beforeReset?.networkReceiveBytes, 500)

        try await history.reset()

        // The collector keeps delivering the same cached pre-reset interval after reset.
        for offset in [1.0, 2.0] {
            let timestamp = preResetEnd.addingTimeInterval(offset)
            let cached = appGroup(id: appID, name: "ResetBoundary", process: process, at: timestamp,
                                  networkReceiveRate: 100, networkReceiveInterval: preResetInterval)
            try await history.record(snapshot: snapshotWithGroups([cached], at: timestamp,
                networkReceiveRate: 100, networkReceiveInterval: preResetInterval))
        }
        let afterCached = try await history.summaries(lastDays: 30, through: preResetEnd.addingTimeInterval(2)).first
        let appAfterCached = try await history.applicationSummaries(lastDays: 30,
            through: preResetEnd.addingTimeInterval(2)).first
        XCTAssertEqual(afterCached?.networkReceiveBytes ?? 0, 0)
        XCTAssertEqual(appAfterCached?.networkReceiveBytes ?? 0, 0)

        // A measurement that starts after the reset is still counted.
        let freshStart = Date().addingTimeInterval(1)
        let freshInterval = DateInterval(start: freshStart, end: freshStart.addingTimeInterval(5))
        for timestamp in [freshStart, freshInterval.end] {
            let group = appGroup(id: appID, name: "ResetBoundary", process: process, at: timestamp,
                                 networkReceiveRate: 20, networkReceiveInterval: freshInterval)
            try await history.record(snapshot: snapshotWithGroups([group], at: timestamp,
                networkReceiveRate: 20, networkReceiveInterval: freshInterval))
        }
        let freshEnd = freshInterval.end
        let system = try await history.summaries(lastDays: 30, through: freshEnd).first
        let application = try await history.applicationSummaries(lastDays: 30, through: freshEnd).first
        XCTAssertEqual(system?.networkReceiveBytes, 100)
        XCTAssertEqual(application?.networkReceiveBytes, 100)

        // The reset boundary is persisted, so a reopened store must not replay the pre-reset interval.
        let reopened = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let replayTimestamp = freshEnd.addingTimeInterval(1)
        let replay = appGroup(id: appID, name: "ResetBoundary", process: process, at: replayTimestamp,
                              networkReceiveRate: 100, networkReceiveInterval: preResetInterval)
        try await reopened.record(snapshot: snapshotWithGroups([replay], at: replayTimestamp,
            networkReceiveRate: 100, networkReceiveInterval: preResetInterval))
        let reopenedSystem = try await reopened.summaries(lastDays: 30, through: replayTimestamp).first
        let reopenedApplication = try await reopened.applicationSummaries(lastDays: 30,
                                                                          through: replayTimestamp).first
        XCTAssertEqual(reopenedSystem?.networkReceiveBytes, 100)
        XCTAssertEqual(reopenedApplication?.networkReceiveBytes, 100)
    }

    func testCollectionAndPermissionFailuresMarkSystemAndApplicationHistoryGaps() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for reason in [MetricUnavailableReason.collectionFailed, .permissionDenied] {
            let databaseURL = try temporaryDatabaseURL()
            defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
            let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
            let process = ProcessIdentity(pid: 958, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                     microseconds: 0))
            let group = appGroup(id: "bundle:com.example.failure|/Applications/Failure.app",
                                 name: "Failure", process: process, at: start,
                                 networkReceiveReason: reason)

            try await history.record(snapshot: snapshotWithGroups([group], at: start,
                                                                   networkReceiveReason: reason))

            let system = try await history.summaries(lastDays: 30, through: start).first
            let application = try await history.applicationSummaries(lastDays: 30, through: start).first
            XCTAssertEqual(system?.gaps, 1, "\(reason) makes system history incomplete")
            XCTAssertEqual(application?.gaps, 1, "\(reason) in an application source makes its history incomplete")
        }
    }

    func testRetentionRemovesExpiredDaysAndResetClearsRows() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredTime = now.addingTimeInterval(-31 * 86_400)
        let process = ProcessIdentity(pid: 956, startTime: .init(secondsSinceEpoch: 1_800_000_000,
                                                                 microseconds: 0))
        let appID = "bundle:com.example.retention|/Applications/Retention.app"

        try await history.record(snapshot: snapshotWithGroups([
            appGroup(id: appID, name: "Retention", process: process, at: expiredTime),
        ], at: expiredTime, cpuPercent: 50))
        try await history.record(snapshot: snapshotWithGroups([
            appGroup(id: appID, name: "Retention", process: process, at: now),
        ], at: now, cpuPercent: 50))

        let retained = try await history.summaries(lastDays: 30, through: now)
        let retainedApplications = try await history.applicationSummaries(lastDays: 30, through: now)
        XCTAssertEqual(retained.count, 1)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(retained.first?.dayStart, utcCalendar.startOfDay(for: now))
        XCTAssertNil(retained.first?.cpuSeconds, "expired baselines must not be integrated into retained days")
        XCTAssertEqual(retained.first?.sampleCount, 1)
        XCTAssertEqual(retained.first?.gaps, 1)
        XCTAssertEqual(retainedApplications.count, 1)
        XCTAssertEqual(retainedApplications.first?.dayStart, utcCalendar.startOfDay(for: now))
        XCTAssertNil(retainedApplications.first?.cpuSeconds)
        XCTAssertEqual(retainedApplications.first?.sampleCount, 1)
        XCTAssertEqual(retainedApplications.first?.gaps, 1)

        try await history.reset()
        let cleared = try await history.summaries(lastDays: 30, through: now)
        let clearedApplications = try await history.applicationSummaries(lastDays: 30, through: now)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(clearedApplications.isEmpty)
    }

    func testRetentionRunsOncePerUTCDayAndFirstRecordAfterLaunchRunsIt() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredDay = now.addingTimeInterval(-31 * 86_400)
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now))
        try insertExpiredDailyTotal(dayStart: expiredDay, at: databaseURL)
        // Same UTC day: the retention pass is skipped, so the expired row survives.
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(1)))
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 1)

        // Next UTC day: retention runs again and removes the expired row.
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(86_400)))
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 0)

        // A freshly launched store always runs retention on its first record.
        try insertExpiredDailyTotal(dayStart: expiredDay, at: databaseURL)
        let relaunched = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        try await relaunched.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(86_401)))
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 0)
    }

    func testAppHistoryUsesActualGroupIdentityAndDoesNotDoubleCountMembers() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 950, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let appA = appGroup(id: "bundle:com.example.alpha|/Applications/Editor.app",
                            name: "Editor", process: process)
        let duplicate = appGroup(id: "bundle:com.example.zeta|/Applications/Editor.app",
                                 name: "Editor Helper", process: process)

        try await history.record(snapshot: snapshotWithGroups([appA, duplicate], at: start))
        try await history.record(snapshot: snapshotWithGroups([appA, duplicate], at: start.addingTimeInterval(1)))

        let summaries = try await history.applicationSummaries(lastDays: 30, through: start.addingTimeInterval(1))
        XCTAssertEqual(summaries.count, 1, "overlapping process membership must not create duplicate totals")
        XCTAssertEqual(summaries[0].application.id, appA.historyIdentity.id)
        XCTAssertEqual(summaries[0].cpuSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].diskReadBytes, 40)
        XCTAssertEqual(summaries[0].diskWriteBytes, 10)
        XCTAssertNil(summaries[0].networkReceiveBytes, "unsupported per-process network must stay unavailable")
        XCTAssertEqual(summaries[0].gaps, 0,
                       "unsupported metrics alone do not make otherwise complete samples gaps")
    }

    func testVersionOneDatabaseMigratesWithoutDroppingTotals() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let day = Int64(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 / 86_400) * 86_400
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE daily_totals (
            day_start INTEGER PRIMARY KEY NOT NULL, cpu_seconds REAL,
            disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0,
            counter_resets INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO daily_totals(day_start,cpu_seconds,disk_read_bytes,disk_write_bytes,
            network_receive_bytes,network_transmit_bytes,sample_count,gaps,counter_resets)
            VALUES(\(day),12.5,10,20,30,40,3,1,0);
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let summaries = try await history.summaries(lastDays: 30,
                                                    through: Date(timeIntervalSince1970: TimeInterval(day)))
        let appSummaries = try await history.applicationSummaries(lastDays: 30,
                                                                  through: Date(timeIntervalSince1970: TimeInterval(day)))
        XCTAssertEqual(summaries.first?.cpuSeconds, 12.5)
        XCTAssertEqual(summaries.first?.sampleCount, 3)
        XCTAssertTrue(appSummaries.isEmpty)
    }

    func testVersionTwoDatabaseAddsMissingApplicationColumnsWithoutDroppingTotals() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let day = Int64(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 / 86_400) * 86_400
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE daily_totals (
            day_start INTEGER PRIMARY KEY NOT NULL, cpu_seconds REAL,
            disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO daily_totals(day_start,cpu_seconds,disk_read_bytes,disk_write_bytes,
            network_receive_bytes,network_transmit_bytes,sample_count,gaps)
            VALUES(\(day),12.5,10,20,30,40,3,1);
        CREATE TABLE application_daily_totals (
            day_start INTEGER NOT NULL, application_id TEXT NOT NULL,
            application_name TEXT NOT NULL, executable_path TEXT,
            cpu_seconds REAL, disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day_start, application_id)
        );
        INSERT INTO application_daily_totals(day_start,application_id,application_name,
            executable_path,cpu_seconds,disk_read_bytes,disk_write_bytes,
            network_receive_bytes,network_transmit_bytes,sample_count,gaps)
            VALUES(\(day),'bundle:com.example.legacy','Legacy','/Applications/Legacy.app',
            7.5,1,2,3,4,2,0);
        PRAGMA user_version = 2;
        """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let summaries = try await history.summaries(lastDays: 30,
                                                    through: Date(timeIntervalSince1970: TimeInterval(day)))
        let appSummaries = try await history.applicationSummaries(lastDays: 30,
                                                                  through: Date(timeIntervalSince1970: TimeInterval(day)))
        XCTAssertEqual(summaries.first?.cpuSeconds, 12.5)
        XCTAssertEqual(summaries.first?.sampleCount, 3)
        XCTAssertEqual(summaries.first?.counterResets, 0, "new columns must be added with defaults")
        XCTAssertEqual(appSummaries.count, 1)
        XCTAssertEqual(appSummaries.first?.cpuSeconds, 7.5)
        XCTAssertEqual(appSummaries.first?.application.name, "Legacy")
        XCTAssertEqual(appSummaries.first?.application.association, .standalone,
                       "application rows from before the association column default to standalone")
    }

    func testVersionThreeDatabaseAddsMeasurementStateWithoutDroppingTotals() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let day = Int64(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 / 86_400) * 86_400
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE daily_totals (
            day_start INTEGER PRIMARY KEY NOT NULL, cpu_seconds REAL,
            disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0,
            counter_resets INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO daily_totals(day_start,cpu_seconds,disk_read_bytes,disk_write_bytes,
            network_receive_bytes,network_transmit_bytes,sample_count,gaps,counter_resets)
            VALUES(\(day),12.5,10,20,30,40,3,1,2);
        CREATE TABLE application_daily_totals (
            day_start INTEGER NOT NULL, application_id TEXT NOT NULL,
            application_name TEXT NOT NULL, executable_path TEXT, association TEXT NOT NULL,
            cpu_seconds REAL, disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0,
            counter_resets INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day_start, application_id)
        );
        INSERT INTO application_daily_totals(day_start,application_id,application_name,
            executable_path,association,cpu_seconds,disk_read_bytes,disk_write_bytes,
            network_receive_bytes,network_transmit_bytes,sample_count,gaps,counter_resets)
            VALUES(\(day),'bundle:com.example.v3','Version Three','/Applications/V3.app',
            'applicationBundle',7.5,1,2,3,4,2,1,0);
        CREATE TABLE monitoring_state (
            state_id INTEGER PRIMARY KEY CHECK(state_id = 1),
            last_collection_timestamp REAL NOT NULL, session_id TEXT NOT NULL
        );
        CREATE TABLE application_sample_state (
            application_id TEXT PRIMARY KEY NOT NULL, last_timestamp REAL NOT NULL
        );
        PRAGMA user_version = 3;
        """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let through = Date(timeIntervalSince1970: TimeInterval(day))
        let summaries = try await history.summaries(lastDays: 30, through: through)
        let appSummaries = try await history.applicationSummaries(lastDays: 30, through: through)
        XCTAssertEqual(summaries.first?.cpuSeconds, 12.5)
        XCTAssertEqual(summaries.first?.networkReceiveBytes, 30)
        XCTAssertEqual(summaries.first?.sampleCount, 3)
        XCTAssertEqual(summaries.first?.counterResets, 2)
        XCTAssertEqual(appSummaries.first?.cpuSeconds, 7.5)
        XCTAssertEqual(appSummaries.first?.networkTransmitBytes, 4)
        XCTAssertEqual(appSummaries.first?.application.name, "Version Three")

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), SQLiteMonitoringHistoryStore.schemaVersion)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(database,
            "SELECT COUNT(*) FROM network_measurement_state", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 0)
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    func testUnknownOlderSchemaFailsClosed() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let unknownSQL = """
        CREATE TABLE daily_totals (legacy_timestamp INTEGER PRIMARY KEY, cpu_seconds REAL);
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(database, unknownSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        do {
            _ = try await history.summaries(lastDays: 30, through: Date())
            XCTFail("an unrecognized older schema must not reach runtime column errors")
        } catch {
            XCTAssertEqual(error as? MonitoringHistoryError, .unsupportedSchema(1))
        }
    }

    func testMultipleApplicationTotalsAreBoundPerRowWithinOneTick() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let processes = (0..<3).map { offset in
            ProcessIdentity(pid: pid_t(1000 + offset),
                            startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        }
        let groups = processes.enumerated().map { index, process in
            appGroup(id: "bundle:com.example.app\(index)|/Applications/App\(index).app",
                     name: "App \(index)", process: process)
        }

        try await history.record(snapshot: snapshotWithGroups(groups, at: start))
        try await history.record(snapshot: snapshotWithGroups(groups, at: start.addingTimeInterval(1)))

        let summaries = try await history.applicationSummaries(lastDays: 30,
                                                               through: start.addingTimeInterval(1))
        XCTAssertEqual(summaries.count, groups.count)
        for group in groups {
            let summary = summaries.first { $0.application.id == group.historyIdentity.id }
            XCTAssertEqual(summary?.application.name, group.historyIdentity.name)
            XCTAssertEqual(summary?.sampleCount, 2)
            XCTAssertEqual(summary?.cpuSeconds ?? 0, 2, accuracy: 0.0001)
            XCTAssertEqual(summary?.diskReadBytes, 40)
        }
    }

    func testHistoryStorageFailureSurfacesAsAnError() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("microgravity-history-is-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: directoryURL)

        do {
            try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: Date()))
            XCTFail("SQLite failure must reach the caller")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    private func insertExpiredDailyTotal(dayStart: Date, at databaseURL: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO daily_totals (day_start, sample_count) VALUES (\(Int64(dayStart.timeIntervalSince1970)), 1)"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func expiredDailyTotalCount(dayStart: Date, at databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM daily_totals WHERE day_start = ?",
                                          -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(dayStart.timeIntervalSince1970))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microgravity-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    private func appGroup(id: String, name: String, process: ProcessIdentity,
                          at timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000),
                          cpuPercent: Double = 50, diskReadRate: Double = 40,
                          diskWriteRate: Double = 10, networkReceiveRate: Double? = nil,
                          networkTransmitRate: Double? = nil,
                          networkReceiveInterval: DateInterval? = nil,
                          networkTransmitInterval: DateInterval? = nil,
                          diskReadIsPartial: Bool = false,
                          networkReceiveReason: MetricUnavailableReason? = nil,
                          networkTransmitReason: MetricUnavailableReason? = nil) -> ProcessGroupSnapshot {
        let historyIdentity = ApplicationHistoryIdentity(id: id, name: name,
                                                         executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
                                                         association: .applicationBundle)
        return ProcessGroupSnapshot(
            id: process, title: name, ownerUID: UInt32(getuid()),
            executablePath: historyIdentity.executablePath, association: .applicationBundle,
            historyIdentity: historyIdentity, members: [process],
            cpuPercent: MetricReading(value: cpuPercent, unit: .percent, timestamp: timestamp),
            memoryBytes: MetricReading(value: 1_000, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: MetricReading(value: diskReadRate, unit: .bytesPerSecond,
                                                  timestamp: timestamp,
                                                  detail: diskReadIsPartial ? "partial contributor" : nil,
                                                  isPartial: diskReadIsPartial),
            diskWriteBytesPerSecond: MetricReading(value: diskWriteRate, unit: .bytesPerSecond,
                                                   timestamp: timestamp),
            networkReceiveBytesPerSecond: networkReceiveReason.map {
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0)
            } ?? networkReceiveRate.map {
                MetricReading(value: $0, unit: .bytesPerSecond, timestamp: timestamp,
                              measurementInterval: networkReceiveInterval)
            } ?? MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .unsupported),
            networkTransmitBytesPerSecond: networkTransmitReason.map {
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0)
            } ?? networkTransmitRate.map {
                MetricReading(value: $0, unit: .bytesPerSecond, timestamp: timestamp,
                              measurementInterval: networkTransmitInterval)
            } ?? MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .unsupported))
    }

    private func snapshotWithGroups(_ groups: [ProcessGroupSnapshot], at timestamp: Date,
                                   cpuPercent: Double = 0, diskReadRate: Double = 0,
                                   diskWriteRate: Double = 0, networkReceiveRate: Double = 0,
                                   networkTransmitRate: Double = 0, diskReadIsPartial: Bool = false,
                                   networkReceiveInterval: DateInterval? = nil,
                                   networkTransmitInterval: DateInterval? = nil,
                                   networkReceiveReason: MetricUnavailableReason? = nil,
                                   networkTransmitReason: MetricUnavailableReason? = nil) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp, cpuPercent: cpuPercent,
                                             diskReadRate: diskReadRate, diskWriteRate: diskWriteRate,
                                             networkReceiveRate: networkReceiveRate,
                                             networkTransmitRate: networkTransmitRate).system
        let system = SystemMetricsSnapshot(
            capacityCores: base.capacityCores,
            cpuPercent: base.cpuPercent,
            perCoreCPUPercent: base.perCoreCPUPercent,
            memoryUsedBytes: base.memoryUsedBytes,
            memoryAvailableBytes: base.memoryAvailableBytes,
            memoryTotalBytes: base.memoryTotalBytes,
            memoryPressure: base.memoryPressure,
            swapUsedBytes: base.swapUsedBytes,
            swapTotalBytes: base.swapTotalBytes,
            diskReadBytesPerSecond: MetricReading(value: diskReadRate, unit: .bytesPerSecond,
                                                  timestamp: timestamp,
                                                  detail: diskReadIsPartial ? "partial contributor" : nil,
                                                  isPartial: diskReadIsPartial),
            diskWriteBytesPerSecond: base.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: networkReceiveReason.map {
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0)
            } ?? MetricReading(value: networkReceiveRate, unit: .bytesPerSecond, timestamp: timestamp,
                               measurementInterval: networkReceiveInterval),
            networkTransmitBytesPerSecond: networkTransmitReason.map {
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0)
            } ?? MetricReading(value: networkTransmitRate, unit: .bytesPerSecond, timestamp: timestamp,
                               measurementInterval: networkTransmitInterval),
            networkInterfaces: base.networkInterfaces)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: groups,
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                  capabilities: [:])
    }
}
