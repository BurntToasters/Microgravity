import XCTest
import Darwin
import SQLite3
@testable import Microgravity

final class SQLiteMonitoringHistoryStoreTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    /// 2027-01-15 00:00 in America/Los_Angeles (08:00 UTC). Used as a local midnight.
    private let localJanuary15 = Date(timeIntervalSince1970: 1_800_000_000)
    /// UTC midnight of the same date: the day key schema 5 and earlier stored for it.
    private let utcJanuary15: Int64 = 1_799_971_200

    func testPersistsDailyTotalsAndExplicitGapResetCounts() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                      cpuPercent: 50, diskReadRate: 100,
                                                                      diskWriteRate: 10, networkReceiveRate: 20,
                                                                      networkTransmitRate: 30))
        // A sleep or pause is not a gap: its interval contributes nothing.
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
        XCTAssertEqual(firstRead?.gaps, 0)
        XCTAssertEqual(firstRead?.counterResets, 1)

        // Reopening proves the history is persistent, not held only in process memory.
        try await history.flush()
        let reopened = makeHistory(databaseURL)
        let persisted = try await reopened.summaries(lastDays: 30, through: start.addingTimeInterval(3)).first
        XCTAssertEqual(persisted, firstRead)
    }

    func testRelaunchDoesNotBridgeOrCountAGap() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSession = makeHistory(databaseURL)

        try await firstSession.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await firstSession.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                          cpuPercent: 50))
        try await firstSession.flush()
        let beforeRelaunch = try await firstSession.summaries(lastDays: 30,
                                                              through: start.addingTimeInterval(1)).first

        let relaunched = makeHistory(databaseURL)
        try await relaunched.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(2),
                                                                         cpuPercent: 90))
        let afterRelaunch = try await relaunched.summaries(lastDays: 30,
                                                           through: start.addingTimeInterval(2)).first

        XCTAssertEqual(afterRelaunch?.cpuSeconds, beforeRelaunch?.cpuSeconds,
                       "a fresh monitoring session must not integrate counters across process relaunch")
        XCTAssertEqual(afterRelaunch?.gaps, 0, "a relaunch is not a gap")
        XCTAssertEqual(beforeRelaunch?.gaps, 0)
    }

    func testRelaunchSleepPauseAndNewApplicationsAreNotGaps() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 965, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let appID = "bundle:com.example.quiet|/Applications/Quiet.app"
        let group = appGroup(id: appID, name: "Quiet", process: process)

        let first = makeHistory(databaseURL)
        try await first.record(snapshot: snapshotWithGroups([group], at: start, cpuPercent: 50))
        try await first.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(1), cpuPercent: 50))
        try await first.flush()

        // Relaunch, then the Mac sleeps for an hour, then a pause marks the resumed sample.
        let relaunched = makeHistory(databaseURL)
        try await relaunched.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(2), cpuPercent: 50))
        try await relaunched.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(3602), cpuPercent: 50))
        try await relaunched.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(3603),
                                                                         cpuReason: .sleepGap))
        // The application reappears after its absence, so it has no baseline yet.
        try await relaunched.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(3604), cpuPercent: 50))
        try await relaunched.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(3605), cpuPercent: 50))
        try await relaunched.flush()

        let end = start.addingTimeInterval(3605)
        let system = try await relaunched.summaries(lastDays: 30, through: end).first
        let application = try await relaunched.applicationSummaries(lastDays: 30, through: end).first
        XCTAssertEqual(system?.gaps, 0)
        XCTAssertEqual(application?.gaps, 0)
        // One interval per session before the gap (2 CPU-seconds), then the two post-pause intervals
        // (2 CPU-seconds each). The relaunch, sleep, and reappearance contribute nothing.
        XCTAssertEqual(system?.cpuSeconds ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(application?.cpuSeconds ?? 0, 4, accuracy: 0.0001)
    }

    func testCollectionFailedReadingProducesAGap() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                      cpuReason: .collectionFailed))

        let summary = try await history.summaries(lastDays: 30, through: start.addingTimeInterval(1)).first
        XCTAssertEqual(summary?.gaps, 1, "a reading lost to a collection failure is a gap")
        XCTAssertNil(summary?.cpuSeconds, "the lost interval must stay missing rather than become zero")
    }

    func testBufferedTotalsAreVisibleBeforeFlushAndPersistAfterFlush() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 964, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let group = appGroup(id: "bundle:com.example.buffered|/Applications/Buffered.app",
                             name: "Buffered", process: process)

        try await history.record(snapshot: snapshotWithGroups([group], at: start, cpuPercent: 50))
        try await history.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(1), cpuPercent: 50))

        let end = start.addingTimeInterval(1)
        let buffered = try await history.summaries(lastDays: 30, through: end).first
        let bufferedApplication = try await history.applicationSummaries(lastDays: 30, through: end).first
        XCTAssertEqual(buffered?.sampleCount, 2)
        XCTAssertEqual(buffered?.cpuSeconds ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(bufferedApplication?.cpuSeconds ?? 0, 2, accuracy: 0.0001)

        let otherConnection = makeHistory(databaseURL)
        let beforeFlush = try await otherConnection.summaries(lastDays: 30, through: end)
        XCTAssertTrue(beforeFlush.isEmpty, "buffered totals must not reach SQLite before a flush")

        try await history.flush()
        let reopened = makeHistory(databaseURL)
        let persisted = try await reopened.summaries(lastDays: 30, through: end).first
        let persistedApplication = try await reopened.applicationSummaries(lastDays: 30, through: end).first
        XCTAssertEqual(persisted, buffered)
        XCTAssertEqual(persistedApplication, bufferedApplication)
    }

    func testResetDiscardsBufferedTotals() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start, cpuPercent: 10))
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(1),
                                                                      cpuPercent: 50))
        let beforeReset = try await history.summaries(lastDays: 30, through: start.addingTimeInterval(1))
        XCTAssertEqual(beforeReset.first?.sampleCount, 2)

        try await history.reset()
        let afterReset = try await history.summaries(lastDays: 30, through: start.addingTimeInterval(1))
        XCTAssertTrue(afterReset.isEmpty, "reset must discard buffered totals")

        try await history.flush()
        let reopened = makeHistory(databaseURL)
        let persisted = try await reopened.summaries(lastDays: 30, through: start.addingTimeInterval(1))
        XCTAssertTrue(persisted.isEmpty, "a flush after reset must not resurrect discarded totals")

        // Integration restarts after reset: the pre-reset sample is no longer a baseline.
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: start.addingTimeInterval(2),
                                                                      cpuPercent: 50))
        let afterNewSample = try await history.summaries(lastDays: 30, through: start.addingTimeInterval(2)).first
        XCTAssertEqual(afterNewSample?.sampleCount, 1)
        XCTAssertNil(afterNewSample?.cpuSeconds)
    }

    func testInMemoryBaselineReloadsAfterAnotherStoreCommits() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let first = makeHistory(databaseURL)
        let second = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 952, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let group = appGroup(id: "bundle:com.example.shared|/Applications/Shared.app",
                             name: "Shared", process: process)

        // Each store commits before the other records, so each one sees the other's baseline.
        try await first.record(snapshot: snapshotWithGroups([group], at: start, cpuPercent: 50))
        try await first.flush()
        try await second.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(1), cpuPercent: 50))
        try await second.flush()
        try await first.record(snapshot: snapshotWithGroups([group], at: start.addingTimeInterval(2), cpuPercent: 50))
        try await first.flush()
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
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let process = ProcessIdentity(pid: 951, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let group = appGroup(id: "bundle:com.example.commit|/Applications/Editor.app",
                             name: "Editor", process: process)

        try await history.record(snapshot: snapshotWithGroups([group], at: start))
        try await history.flush()

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
        try await history.record(snapshot: snapshotWithGroups([measuredGroup],
            at: start.addingTimeInterval(1), networkReceiveRate: 20,
            networkReceiveInterval: measuredInterval))
        do {
            try await history.flush()
            XCTFail("injected transaction failure must reach the caller")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER reject_collection_state", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        // The failed commit keeps its buffer, and the remembered measurement is not counted again on retry.
        let retryGroup = appGroup(id: "bundle:com.example.commit|/Applications/Editor.app",
                                  name: "Editor", process: process, at: start.addingTimeInterval(2),
                                  networkReceiveRate: 20, networkReceiveInterval: measuredInterval)
        try await history.record(snapshot: snapshotWithGroups([retryGroup], at: start.addingTimeInterval(2),
            networkReceiveRate: 20, networkReceiveInterval: measuredInterval))
        try await history.flush()
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

    func testSystemAndApplicationIntervalsSplitAtLocalMidnight() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let losAngelesCalendar = calendar(losAngeles)
        let previousMidnight = losAngelesCalendar.startOfDay(for: localJanuary15)
        let midnight = losAngelesCalendar.date(byAdding: .day, value: 1, to: previousMidnight)!
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
        XCTAssertEqual(systemSummaries.map(\.dayStart), [previousMidnight, midnight])
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
        XCTAssertEqual(systemSummaries.map(\.gaps), [0, 1], "partial data is a gap on the endpoint day")
        XCTAssertEqual(systemSummaries.map(\.counterResets), [0, 1])

        XCTAssertEqual(appSummaries.map(\.dayStart), [previousMidnight, midnight])
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

    func testLocalDaysFollowDaylightSavingTransitions() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let losAngelesCalendar = calendar(losAngeles)
        // 2026-03-08 begins the 23-hour spring-forward day. 2026-11-01 begins the 25-hour fall-back day.
        let springDay = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let springNext = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let fallDay = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let fallNext = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertEqual(springNext.timeIntervalSince(springDay), 23 * 3_600)
        XCTAssertEqual(fallNext.timeIntervalSince(fallDay), 25 * 3_600)

        // A 20-second system network measurement straddles each local midnight and is split evenly.
        // Each boundary is read before the next record, because the later record is eight months on and
        // its retention pass would correctly discard the earlier days.
        for (boundary, expectedDays) in [(springNext, [springDay, springNext]), (fallNext, [fallDay, fallNext])] {
            let interval = DateInterval(start: boundary.addingTimeInterval(-10), end: boundary.addingTimeInterval(10))
            try await history.record(snapshot: snapshotWithGroups([], at: boundary.addingTimeInterval(10),
                networkReceiveRate: 10, networkReceiveInterval: interval))
            let summaries = try await history.summaries(lastDays: 3, through: boundary.addingTimeInterval(10))
            XCTAssertEqual(summaries.map(\.dayStart), expectedDays)
            XCTAssertEqual(summaries.map(\.networkReceiveBytes), [100, 100])
        }
    }

    func testRetentionRemovesExpiredDaysAndResetClearsRows() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
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
        let utcCalendar = calendar(utc)
        XCTAssertEqual(retained.first?.dayStart, utcCalendar.startOfDay(for: now))
        XCTAssertNil(retained.first?.cpuSeconds, "expired baselines must not be integrated into retained days")
        XCTAssertEqual(retained.first?.sampleCount, 1)
        XCTAssertEqual(retained.first?.gaps, 0, "an elapsed span longer than a sample is not a gap")
        XCTAssertEqual(retainedApplications.count, 1)
        XCTAssertEqual(retainedApplications.first?.dayStart, utcCalendar.startOfDay(for: now))
        XCTAssertNil(retainedApplications.first?.cpuSeconds)
        XCTAssertEqual(retainedApplications.first?.sampleCount, 1)
        XCTAssertEqual(retainedApplications.first?.gaps, 0)

        try await history.reset()
        let cleared = try await history.summaries(lastDays: 30, through: now)
        let clearedApplications = try await history.applicationSummaries(lastDays: 30, through: now)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(clearedApplications.isEmpty)
    }

    func testRetentionRunsOncePerLocalDayAndFirstRecordAfterLaunchRunsIt() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredDay = now.addingTimeInterval(-31 * 86_400)
        let history = makeHistory(databaseURL)

        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now))
        try insertExpiredDailyTotal(dayStart: expiredDay, at: databaseURL)
        // Same local day: the retention pass is skipped, so the expired row survives.
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(1)))
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 1)

        // Next local day: retention runs again and removes the expired row when the buffer commits.
        try await history.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(86_400)))
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 0)

        // A freshly launched store always runs retention on its first record.
        try insertExpiredDailyTotal(dayStart: expiredDay, at: databaseURL)
        let relaunched = makeHistory(databaseURL)
        try await relaunched.record(snapshot: CoreTestFixtures.snapshot(timestamp: now.addingTimeInterval(86_401)))
        try await relaunched.flush()
        XCTAssertEqual(try expiredDailyTotalCount(dayStart: expiredDay, at: databaseURL), 0)
    }

    func testAppHistoryUsesActualGroupIdentityAndDoesNotDoubleCountMembers() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
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
        let day = utcJanuary15
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

        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let summaries = try await history.summaries(lastDays: 30, through: localJanuary15)
        let appSummaries = try await history.applicationSummaries(lastDays: 30, through: localJanuary15)
        XCTAssertEqual(summaries.first?.dayStart, localJanuary15, "the legacy UTC day is re-keyed to its local day")
        XCTAssertEqual(summaries.first?.cpuSeconds, 12.5)
        XCTAssertEqual(summaries.first?.sampleCount, 3)
        XCTAssertTrue(appSummaries.isEmpty)
    }

    func testVersionTwoDatabaseAddsMissingApplicationColumnsWithoutDroppingTotals() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let day = utcJanuary15
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

        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let summaries = try await history.summaries(lastDays: 30, through: localJanuary15)
        let appSummaries = try await history.applicationSummaries(lastDays: 30, through: localJanuary15)
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
        let day = utcJanuary15
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

        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let summaries = try await history.summaries(lastDays: 30, through: localJanuary15)
        let appSummaries = try await history.applicationSummaries(lastDays: 30, through: localJanuary15)
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

    func testVersionFiveDatabaseRekeysUTCDaysToLocalDaysAndMergesCollisions() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let utcCalendar = calendar(utc)
        let losAngelesCalendar = calendar(losAngeles)
        let utcMarch10 = utcCalendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let utcMarch11 = utcCalendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!
        let localMarch10 = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let localMarch11 = losAngelesCalendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!
        let utcMarch10Key = Int64(utcMarch10.timeIntervalSince1970)
        let utcMarch11Key = Int64(utcMarch11.timeIntervalSince1970)
        let localMarch10Key = Int64(localMarch10.timeIntervalSince1970)

        // The local-keyed row sits on the same local day that the UTC-keyed March 10 row maps to, so
        // the migration has to merge the two with the upsert rules.
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
        INSERT INTO daily_totals VALUES(\(utcMarch10Key), 10, 5, NULL, 5, NULL, 2, 1, 0);
        INSERT INTO daily_totals VALUES(\(localMarch10Key), 5, NULL, NULL, NULL, NULL, 1, 0, 1);
        INSERT INTO daily_totals VALUES(\(utcMarch11Key), 7, NULL, NULL, NULL, NULL, 1, 0, 0);
        CREATE TABLE application_daily_totals (
            day_start INTEGER NOT NULL, application_id TEXT NOT NULL,
            application_name TEXT NOT NULL, executable_path TEXT, association TEXT NOT NULL,
            cpu_seconds REAL, disk_read_bytes INTEGER, disk_write_bytes INTEGER,
            network_receive_bytes INTEGER, network_transmit_bytes INTEGER,
            sample_count INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0,
            counter_resets INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(day_start, application_id)
        );
        INSERT INTO application_daily_totals VALUES(\(utcMarch10Key), 'bundle:com.example.rekey', 'Old Name',
            '/Applications/Rekey.app', 'applicationBundle', 4, NULL, NULL, NULL, NULL, 1, 0, 0);
        INSERT INTO application_daily_totals VALUES(\(localMarch10Key), 'bundle:com.example.rekey', 'New Name',
            '/Applications/Rekey.app', 'applicationBundle', 1, NULL, NULL, NULL, NULL, 1, 0, 0);
        CREATE TABLE monitoring_state (
            state_id INTEGER PRIMARY KEY CHECK(state_id = 1),
            last_collection_timestamp REAL NOT NULL, session_id TEXT NOT NULL
        );
        CREATE TABLE application_sample_state (
            application_id TEXT PRIMARY KEY NOT NULL, last_timestamp REAL NOT NULL
        );
        PRAGMA user_version = 5;
        """
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let history = makeHistory(databaseURL, timeZone: losAngeles)
        let summaries = try await history.summaries(lastDays: 30, through: localMarch11)
        XCTAssertEqual(summaries.map(\.dayStart), [localMarch10, localMarch11],
                       "UTC-keyed rows must move to local midnights and leave no UTC keys behind")
        XCTAssertEqual(summaries[0].cpuSeconds ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(summaries[0].sampleCount, 3)
        XCTAssertEqual(summaries[0].gaps, 1)
        XCTAssertEqual(summaries[0].counterResets, 1)
        XCTAssertEqual(summaries[0].diskReadBytes, 5)
        XCTAssertEqual(summaries[0].networkReceiveBytes, 5)
        XCTAssertNil(summaries[0].networkTransmitBytes, "a NULL addend must not turn a missing total into zero")
        XCTAssertEqual(summaries[1].cpuSeconds ?? 0, 7, accuracy: 0.0001)

        let applications = try await history.applicationSummaries(lastDays: 30, through: localMarch11)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.dayStart, localMarch10)
        XCTAssertEqual(applications.first?.application.name, "New Name",
                       "the newest legacy row supplies the application identity")
        XCTAssertEqual(applications.first?.cpuSeconds ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(applications.first?.sampleCount, 2)

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), SQLiteMonitoringHistoryStore.schemaVersion)
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

        let history = makeHistory(databaseURL)
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
        let history = makeHistory(databaseURL)
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

    func testCommitWritesEveryApplicationBaselineInOneTransaction() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let history = makeHistory(databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let groups = (0..<3).map { index in
            appGroup(id: "bundle:com.example.commit\(index)|/Applications/Commit\(index).app",
                     name: "Commit \(index)",
                     process: ProcessIdentity(pid: pid_t(2000 + index),
                                              startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0)))
        }

        try await history.record(snapshot: snapshotWithGroups(groups, at: start))
        try await history.record(snapshot: snapshotWithGroups(groups, at: start.addingTimeInterval(1)))
        // Each application baseline is bound and stepped in one loop during the commit. This must not fail
        // after the first row, which is the case for every app after the first.
        try await history.flush()

        let reopened = makeHistory(databaseURL)
        let persisted = try await reopened.applicationSummaries(lastDays: 30,
                                                                through: start.addingTimeInterval(1))
        XCTAssertEqual(persisted.count, groups.count)
        for group in groups {
            let summary = persisted.first { $0.application.id == group.historyIdentity.id }
            XCTAssertEqual(summary?.sampleCount, 2)
            XCTAssertEqual(summary?.cpuSeconds ?? 0, 2, accuracy: 0.0001)
        }
        XCTAssertEqual(applicationSampleStateCount(at: databaseURL), groups.count,
                       "every application's baseline must be saved for the next launch")
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

    /// Opens a store that buckets days in the given zone. Defaults to UTC so tests stay independent of the host.
    private func makeHistory(_ databaseURL: URL, timeZone: TimeZone? = nil) -> SQLiteMonitoringHistoryStore {
        SQLiteMonitoringHistoryStore(databaseURL: databaseURL, timeZone: timeZone ?? utc)
    }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
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

    private func applicationSampleStateCount(at databaseURL: URL) -> Int {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM application_sample_state", -1,
                                          &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
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
