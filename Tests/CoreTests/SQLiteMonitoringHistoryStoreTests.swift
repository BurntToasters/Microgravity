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

        do {
            try await history.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(1)))
            XCTFail("injected transaction failure must reach the caller")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_collection_state", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        try await history.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(2)))
        let summary = try await history.applicationSummaries(lastDays: 30,
                                                             through: start.addingTimeInterval(2)).first
        XCTAssertEqual(summary?.cpuSeconds ?? 0, 4, accuracy: 0.0001,
                       "the committed t0 baseline must survive the failed t1 transaction")
    }

    func testRetentionRemovesExpiredDaysAndResetClearsRows() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = SQLiteMonitoringHistoryStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(-31 * 86_400)))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now))

        let retained = try await history.summaries(lastDays: 30, through: now)
        XCTAssertEqual(retained.count, 1)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(retained.first?.dayStart, utcCalendar.startOfDay(for: now))

        try await history.reset()
        let cleared = try await history.summaries(lastDays: 30, through: now)
        XCTAssertTrue(cleared.isEmpty)
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

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microgravity-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    private func appGroup(id: String, name: String, process: ProcessIdentity) -> ProcessGroupSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let historyIdentity = ApplicationHistoryIdentity(id: id, name: name,
                                                         executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
                                                         association: .applicationBundle)
        return ProcessGroupSnapshot(
            id: process, title: name, ownerUID: UInt32(getuid()),
            executablePath: historyIdentity.executablePath, association: .applicationBundle,
            historyIdentity: historyIdentity, members: [process],
            cpuPercent: MetricReading(value: 50, unit: .percent, timestamp: timestamp),
            memoryBytes: MetricReading(value: 1_000, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: MetricReading(value: 40, unit: .bytesPerSecond, timestamp: timestamp),
            diskWriteBytesPerSecond: MetricReading(value: 10, unit: .bytesPerSecond, timestamp: timestamp),
            networkReceiveBytesPerSecond: MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                        reason: .unsupported),
            networkTransmitBytesPerSecond: MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                         reason: .unsupported))
    }

    private func snapshotWithGroups(_ groups: [ProcessGroupSnapshot], at timestamp: Date) -> MonitoringSnapshot {
        let system = CoreTestFixtures.system(timestamp: timestamp)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: groups,
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                  capabilities: [:])
    }
}
