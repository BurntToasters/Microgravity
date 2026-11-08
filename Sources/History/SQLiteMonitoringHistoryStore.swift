import Foundation
import SQLite3
import Darwin

public enum MonitoringHistoryError: LocalizedError, Equatable {
    case databaseUnavailable(String)
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int32)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .databaseUnavailable(message): return message
        case let .sqlite(code, message): return "SQLite error \(code): \(message)"
        case let .unsupportedSchema(version): return "Unsupported history schema version \(version)."
        case let .invalidRequest(message): return message
        }
    }
}

/// Local-day arithmetic for history buckets. A `day_start` is the local midnight that opens the day,
/// so 23- and 25-hour daylight-saving days are sliced at real local midnights.
struct HistoryDayCalendar: Sendable {
    private let fixedTimeZone: TimeZone?
    private var timeZone: TimeZone
    private var calendar: Calendar

    /// A fixed zone is used as given (tests). Nil follows the system zone, re-read on each use.
    init(timeZone: TimeZone? = nil) {
        let zone = timeZone ?? TimeZone.current
        fixedTimeZone = timeZone
        self.timeZone = zone
        calendar = Self.makeCalendar(zone)
    }

    /// The gregorian calendar for the zone in effect now. It is rebuilt only when the zone changes.
    mutating func current() -> Calendar {
        let zone = fixedTimeZone ?? TimeZone.current
        if zone != timeZone {
            timeZone = zone
            calendar = Self.makeCalendar(zone)
        }
        return calendar
    }

    static func dayStart(containing date: Date, in calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayStart(_ dayStart: Date, addingDays days: Int, in calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: dayStart)
            ?? dayStart.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private static func makeCalendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

/// Stores only daily aggregate totals. System history deliberately excludes
/// process names, command lines, paths, and destination values. Application
/// history stores application display names and executable bundle paths so
/// per-application totals can be attributed and presented.
///
/// Totals are buffered in memory and committed in one transaction at most every
/// `flushInterval` seconds of sample time, or when `flush()` is called. Summaries
/// include the buffered totals, so readers always see the latest samples.
public actor SQLiteMonitoringHistoryStore: MonitoringHistoryManaging {
    public static let schemaVersion: Int32 = 6
    public static let retentionDays = 30
    static let maximumRememberedMeasurementIntervalsPerStream = 128
    /// Buffered totals reach SQLite at most this often while samples are arriving.
    static let flushInterval: TimeInterval = 30
    /// A sample more than this long after its predecessor spans sleep or a stall, so it is not integrated.
    private static let maximumIntegratedInterval: TimeInterval = 30

    private static let dailyTotalsCreateSQL = """
    CREATE TABLE IF NOT EXISTS daily_totals (
        day_start INTEGER PRIMARY KEY NOT NULL,
        cpu_seconds REAL,
        disk_read_bytes INTEGER,
        disk_write_bytes INTEGER,
        network_receive_bytes INTEGER,
        network_transmit_bytes INTEGER,
        sample_count INTEGER NOT NULL DEFAULT 0,
        gaps INTEGER NOT NULL DEFAULT 0,
        counter_resets INTEGER NOT NULL DEFAULT 0
    )
    """

    private static let applicationDailyTotalsCreateSQL = """
    CREATE TABLE IF NOT EXISTS application_daily_totals (
        day_start INTEGER NOT NULL,
        application_id TEXT NOT NULL,
        application_name TEXT NOT NULL,
        executable_path TEXT,
        association TEXT NOT NULL,
        cpu_seconds REAL,
        disk_read_bytes INTEGER,
        disk_write_bytes INTEGER,
        network_receive_bytes INTEGER,
        network_transmit_bytes INTEGER,
        sample_count INTEGER NOT NULL DEFAULT 0,
        gaps INTEGER NOT NULL DEFAULT 0,
        counter_resets INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(day_start, application_id)
    )
    """

    private static let monitoringStateCreateSQL = """
    CREATE TABLE IF NOT EXISTS monitoring_state (
        state_id INTEGER PRIMARY KEY CHECK(state_id = 1),
        last_collection_timestamp REAL NOT NULL,
        session_id TEXT NOT NULL
    )
    """

    private static let applicationSampleStateCreateSQL = """
    CREATE TABLE IF NOT EXISTS application_sample_state (
        application_id TEXT PRIMARY KEY NOT NULL,
        last_timestamp REAL NOT NULL
    )
    """

    private static let networkMeasurementStateCreateSQL = """
    CREATE TABLE IF NOT EXISTS network_measurement_state (
        scope TEXT NOT NULL,
        application_id TEXT NOT NULL DEFAULT '',
        direction TEXT NOT NULL,
        interval_start REAL NOT NULL,
        interval_end REAL NOT NULL,
        PRIMARY KEY(scope, application_id, direction, interval_start, interval_end)
    )
    """

    private static let historyResetStateCreateSQL = """
    CREATE TABLE IF NOT EXISTS history_reset_state (
        state_id INTEGER PRIMARY KEY CHECK(state_id = 1),
        reset_timestamp REAL NOT NULL
    )
    """

    /// Columns read by `readTotals`, in order. Shared by every daily-row query.
    private static let dailyColumns = "cpu_seconds, disk_read_bytes, disk_write_bytes, network_receive_bytes, network_transmit_bytes, sample_count, gaps, counter_resets"

    private static let dailyUpsertSQL = """
    INSERT INTO daily_totals (
        day_start, cpu_seconds, disk_read_bytes, disk_write_bytes,
        network_receive_bytes, network_transmit_bytes, sample_count, gaps, counter_resets
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day_start) DO UPDATE SET
        cpu_seconds = CASE WHEN excluded.cpu_seconds IS NULL THEN daily_totals.cpu_seconds
            ELSE COALESCE(daily_totals.cpu_seconds, 0) + excluded.cpu_seconds END,
        disk_read_bytes = CASE WHEN excluded.disk_read_bytes IS NULL THEN daily_totals.disk_read_bytes
            ELSE COALESCE(daily_totals.disk_read_bytes, 0) + excluded.disk_read_bytes END,
        disk_write_bytes = CASE WHEN excluded.disk_write_bytes IS NULL THEN daily_totals.disk_write_bytes
            ELSE COALESCE(daily_totals.disk_write_bytes, 0) + excluded.disk_write_bytes END,
        network_receive_bytes = CASE WHEN excluded.network_receive_bytes IS NULL THEN daily_totals.network_receive_bytes
            ELSE COALESCE(daily_totals.network_receive_bytes, 0) + excluded.network_receive_bytes END,
        network_transmit_bytes = CASE WHEN excluded.network_transmit_bytes IS NULL THEN daily_totals.network_transmit_bytes
            ELSE COALESCE(daily_totals.network_transmit_bytes, 0) + excluded.network_transmit_bytes END,
        sample_count = daily_totals.sample_count + excluded.sample_count,
        gaps = daily_totals.gaps + excluded.gaps,
        counter_resets = daily_totals.counter_resets + excluded.counter_resets
    """

    private static let applicationUpsertSQL = """
    INSERT INTO application_daily_totals (
        day_start, application_id, application_name, executable_path, association,
        cpu_seconds, disk_read_bytes, disk_write_bytes, network_receive_bytes,
        network_transmit_bytes, sample_count, gaps, counter_resets
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day_start, application_id) DO UPDATE SET
        application_name = excluded.application_name,
        executable_path = excluded.executable_path,
        association = excluded.association,
        cpu_seconds = CASE WHEN excluded.cpu_seconds IS NULL THEN application_daily_totals.cpu_seconds
            ELSE COALESCE(application_daily_totals.cpu_seconds, 0) + excluded.cpu_seconds END,
        disk_read_bytes = CASE WHEN excluded.disk_read_bytes IS NULL THEN application_daily_totals.disk_read_bytes
            ELSE COALESCE(application_daily_totals.disk_read_bytes, 0) + excluded.disk_read_bytes END,
        disk_write_bytes = CASE WHEN excluded.disk_write_bytes IS NULL THEN application_daily_totals.disk_write_bytes
            ELSE COALESCE(application_daily_totals.disk_write_bytes, 0) + excluded.disk_write_bytes END,
        network_receive_bytes = CASE WHEN excluded.network_receive_bytes IS NULL THEN application_daily_totals.network_receive_bytes
            ELSE COALESCE(application_daily_totals.network_receive_bytes, 0) + excluded.network_receive_bytes END,
        network_transmit_bytes = CASE WHEN excluded.network_transmit_bytes IS NULL THEN application_daily_totals.network_transmit_bytes
            ELSE COALESCE(application_daily_totals.network_transmit_bytes, 0) + excluded.network_transmit_bytes END,
        sample_count = application_daily_totals.sample_count + excluded.sample_count,
        gaps = application_daily_totals.gaps + excluded.gaps,
        counter_resets = application_daily_totals.counter_resets + excluded.counter_resets
    """

    private static let monitoringStateUpsertSQL = """
    INSERT INTO monitoring_state(state_id, last_collection_timestamp, session_id)
    VALUES(1, ?, ?)
    ON CONFLICT(state_id) DO UPDATE SET
        last_collection_timestamp = excluded.last_collection_timestamp,
        session_id = excluded.session_id
    """

    private static let applicationSampleUpsertSQL = """
    INSERT INTO application_sample_state(application_id, last_timestamp) VALUES(?, ?)
    ON CONFLICT(application_id) DO UPDATE SET last_timestamp = excluded.last_timestamp
    """

    private static let networkInsertSQL = """
    INSERT OR IGNORE INTO network_measurement_state(
        scope, application_id, direction, interval_start, interval_end
    ) VALUES (?, ?, ?, ?, ?)
    """

    private static let networkDeleteSQL = """
    DELETE FROM network_measurement_state
    WHERE scope = ? AND application_id = ? AND direction = ? AND interval_start = ? AND interval_end = ?
    """

    private struct PriorSample: Equatable {
        let timestamp: Date
        let sessionID: String
    }

    /// Opaque SQLite handle remains actor-owned while open. This wrapper only
    /// makes its lifetime sendable so actor deinitialization can close it safely.
    /// It also owns the prepared statements for the hot paths, finalized before close.
    private final class DatabaseHandle: @unchecked Sendable {
        let pointer: OpaquePointer
        var statements: [String: OpaquePointer] = [:]

        init(_ pointer: OpaquePointer) { self.pointer = pointer }

        deinit {
            for statement in statements.values { sqlite3_finalize(statement) }
            sqlite3_close(pointer)
        }
    }

    /// Additive totals with the same NULL rule as the SQLite upserts: a NULL addend leaves the
    /// total unchanged, and NULL otherwise counts as zero.
    private struct HistoryTotals: Equatable {
        var cpuSeconds: Double?
        var diskReadBytes: UInt64?
        var diskWriteBytes: UInt64?
        var networkReceiveBytes: UInt64?
        var networkTransmitBytes: UInt64?
        var sampleCount = 0
        var gaps = 0
        var counterResets = 0

        mutating func add(_ other: HistoryTotals) {
            cpuSeconds = Self.sum(cpuSeconds, other.cpuSeconds)
            diskReadBytes = Self.sum(diskReadBytes, other.diskReadBytes)
            diskWriteBytes = Self.sum(diskWriteBytes, other.diskWriteBytes)
            networkReceiveBytes = Self.sum(networkReceiveBytes, other.networkReceiveBytes)
            networkTransmitBytes = Self.sum(networkTransmitBytes, other.networkTransmitBytes)
            sampleCount += other.sampleCount
            gaps += other.gaps
            counterResets += other.counterResets
        }

        private static func sum<Value: Numeric>(_ total: Value?, _ addend: Value?) -> Value? {
            guard let addend else { return total }
            return (total ?? 0) + addend
        }
    }

    private struct DayTotals {
        let dayStart: Date
        let totals: HistoryTotals
    }

    /// A slice of an interval that falls on one local day.
    private struct DayPiece {
        let dayStart: Date
        let duration: TimeInterval
    }

    private struct ApplicationDayKey: Hashable {
        let dayStart: Int64
        let applicationID: String
    }

    private struct ApplicationTotals {
        var identity: ApplicationHistoryIdentity
        var totals: HistoryTotals
    }

    private struct NetworkRateTotal {
        let bytes: UInt64?
        let interval: DateInterval?
    }

    private enum NetworkMeasurementDirection: String {
        case receive
        case transmit
    }

    private struct NetworkMeasurementStream: Hashable {
        let scope: String
        let applicationID: String
        let direction: NetworkMeasurementDirection

        static func system(_ direction: NetworkMeasurementDirection) -> NetworkMeasurementStream {
            NetworkMeasurementStream(scope: "system", applicationID: "", direction: direction)
        }

        static func application(_ applicationID: String,
                                _ direction: NetworkMeasurementDirection) -> NetworkMeasurementStream {
            NetworkMeasurementStream(scope: "application", applicationID: applicationID, direction: direction)
        }
    }

    /// Interval endpoints in epoch seconds, exactly as stored.
    private struct NetworkMeasurementInterval: Hashable {
        let start: Double
        let end: Double
    }

    private struct NetworkMeasurementRecord: Hashable {
        let stream: NetworkMeasurementStream
        let interval: NetworkMeasurementInterval
    }

    /// Remembered measurement identities for one stream, oldest first.
    private struct NetworkStreamWindow {
        private(set) var order: [NetworkMeasurementInterval] = []
        private(set) var members: Set<NetworkMeasurementInterval> = []

        var count: Int { order.count }

        /// Returns false when the identity is already remembered.
        mutating func insert(_ interval: NetworkMeasurementInterval) -> Bool {
            guard members.insert(interval).inserted else { return false }
            order.append(interval)
            return true
        }

        mutating func removeOldest() -> NetworkMeasurementInterval? {
            guard !order.isEmpty else { return nil }
            let oldest = order.removeFirst()
            members.remove(oldest)
            return oldest
        }

        mutating func prune(endingBefore seconds: TimeInterval) {
            let kept = order.filter { $0.end >= seconds }
            guard kept.count != order.count else { return }
            order = kept
            members = Set(kept)
        }
    }

    private let databaseURL: URL?
    private let sessionID = UUID().uuidString
    private var dayCalendar: HistoryDayCalendar
    private var database: DatabaseHandle?
    private var priorSample: PriorSample?
    private var priorApplicationSamples: [String: Date] = [:]
    private var collectionStateLoaded = false
    private var observedDataVersion: Int32?
    private var resetBoundary: Date?
    /// Local day of the last retention pass scheduled by this process. Retention is scheduled at most
    /// once per local day; the first record after launch always schedules it.
    private var lastRetentionDay: Date?
    private var networkWindowsLoaded = false
    private var networkWindows: [NetworkMeasurementStream: NetworkStreamWindow] = [:]

    // Buffered totals that have not been committed yet.
    private var pendingDaily: [Int64: HistoryTotals] = [:]
    private var pendingApplications: [ApplicationDayKey: ApplicationTotals] = [:]
    private var pendingNetworkInserts: [NetworkMeasurementRecord] = []
    private var pendingNetworkDeletes: Set<NetworkMeasurementRecord> = []
    private var pendingRetentionCutoff: Date?
    private var hasUnflushedChanges = false
    /// Sample time at which the buffer is committed, if it is not committed sooner.
    private var flushDeadline: Date?

    public init(databaseURL: URL? = nil, timeZone: TimeZone? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        dayCalendar = HistoryDayCalendar(timeZone: timeZone)
    }

    public func record(snapshot: MonitoringSnapshot) async throws {
        let handle = try openDatabase()
        let now = snapshot.timestamp
        let calendar = dayCalendar.current()
        let today = HistoryDayCalendar.dayStart(containing: now, in: calendar)
        let cutoff = HistoryDayCalendar.dayStart(today, addingDays: -(Self.retentionDays - 1), in: calendar)
        let dataVersion = try readDataVersion(on: handle)
        // Another connection's commit replaces this baseline only when nothing here is waiting to commit.
        // Buffered contributions were measured against this process's baseline, so adopting the stored
        // one would count the same interval twice.
        if !collectionStateLoaded || (observedDataVersion != dataVersion && !hasUnflushedChanges) {
            priorSample = try readPriorSample(on: handle.pointer)
            priorApplicationSamples = try readApplicationSamples(on: handle.pointer)
            resetBoundary = try readResetBoundary(on: handle.pointer)
            if !networkWindowsLoaded {
                networkWindows = try readNetworkWindows(on: handle.pointer)
                networkWindowsLoaded = true
            }
            collectionStateLoaded = true
            observedDataVersion = dataVersion
        }
        if lastRetentionDay != today {
            lastRetentionDay = today
            pendingRetentionCutoff = cutoff
            discardBufferedRows(before: cutoff)
        }

        let prior = priorSample
        let priorApplications = priorApplicationSamples
        let sameSession = prior?.sessionID == sessionID
        let elapsed: TimeInterval?
        if sameSession, let prior {
            let gap = now.timeIntervalSince(prior.timestamp)
            elapsed = gap > 0 && gap <= Self.maximumIntegratedInterval ? gap : nil
        } else {
            elapsed = nil
        }
        let hasSleepGap = snapshot.allSystemReadings.contains { $0.unavailableReason == .sleepGap }
        let hasMeasurementGap = Self.hasMeasurementGap(snapshot.systemMeasuredReadings)
        let hasCounterReset = snapshot.allSystemReadings.contains { $0.unavailableReason == .counterReset }
        let validElapsed = hasSleepGap ? nil : elapsed
        let cpuSeconds: Double? = validElapsed.flatMap { interval in
            guard let percent = snapshot.system.cpuPercent.value else { return nil }
            return max(0, percent) / 100 * Double(max(1, snapshot.system.capacityCores)) * interval
        }
        let diskRead = snapshot.system.diskReadBytesPerSecond.value.flatMap { rate in
            validElapsed.map { Self.byteTotal(rate * $0) }
        }
        let diskWrite = snapshot.system.diskWriteBytesPerSecond.value.flatMap { rate in
            validElapsed.map { Self.byteTotal(rate * $0) }
        }
        let historyInterval = validElapsed.flatMap { _ in prior.map { DateInterval(start: $0.timestamp, end: now) } }
        let networkReceive = rateTotal(snapshot.system.networkReceiveBytesPerSecond,
                                       fallbackInterval: historyInterval, cutoff: cutoff,
                                       stream: .system(.receive))
        let networkTransmit = rateTotal(snapshot.system.networkTransmitBytesPerSecond,
                                        fallbackInterval: historyInterval, cutoff: cutoff,
                                        stream: .system(.transmit))

        var systemTotals = dailyTotals(
            from: historyInterval?.start, through: now,
            cpuSeconds: cpuSeconds, diskRead: diskRead, diskWrite: diskWrite,
            networkReceive: nil, networkTransmit: nil,
            gaps: hasMeasurementGap ? 1 : 0, counterResets: hasCounterReset ? 1 : 0,
            calendar: calendar)
        systemTotals += dailyTotals(
            from: networkReceive.interval?.start, through: networkReceive.interval?.end ?? now,
            cpuSeconds: nil, diskRead: nil, diskWrite: nil,
            networkReceive: networkReceive.bytes, networkTransmit: nil,
            gaps: 0, counterResets: 0, sampleCount: 0, calendar: calendar)
        systemTotals += dailyTotals(
            from: networkTransmit.interval?.start, through: networkTransmit.interval?.end ?? now,
            cpuSeconds: nil, diskRead: nil, diskWrite: nil,
            networkReceive: nil, networkTransmit: networkTransmit.bytes,
            gaps: 0, counterResets: 0, sampleCount: 0, calendar: calendar)
        for daily in systemTotals where daily.dayStart >= cutoff {
            pendingDaily[Self.epochKey(daily.dayStart), default: HistoryTotals()].add(daily.totals)
        }

        let currentApplicationSamples = recordApplicationTotals(
            snapshot: snapshot, cutoff: cutoff, previousSamples: priorApplications,
            sameSession: sameSession, calendar: calendar)
        priorSample = PriorSample(timestamp: now, sessionID: sessionID)
        priorApplicationSamples = currentApplicationSamples
        hasUnflushedChanges = true

        let deadline = flushDeadline ?? now.addingTimeInterval(Self.flushInterval)
        flushDeadline = deadline
        // A deadline more than one interval away means the clock moved backwards; commit rather than wait.
        if now >= deadline || now < deadline.addingTimeInterval(-Self.flushInterval) {
            try commitBuffer(on: handle)
        }
    }

    /// Commits every buffered total in one transaction. Failed commits keep the buffer for the next attempt.
    public func flush() async throws {
        guard hasUnflushedChanges else { return }
        try commitBuffer(on: try openDatabase())
    }

    public func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] {
        guard lastDays > 0 else { throw MonitoringHistoryError.invalidRequest("lastDays must be positive") }
        let handle = try openDatabase()
        let calendar = dayCalendar.current()
        let lastDay = HistoryDayCalendar.dayStart(containing: date, in: calendar)
        let firstDay = HistoryDayCalendar.dayStart(lastDay, addingDays: -(min(lastDays, 3650) - 1), in: calendar)
        let firstKey = Self.epochKey(firstDay)
        let lastKey = Self.epochKey(lastDay)

        var merged = try readDailyTotals(from: firstKey, through: lastKey, on: handle.pointer)
        for (key, pending) in pendingDaily where key >= firstKey && key <= lastKey {
            merged[key, default: HistoryTotals()].add(pending)
        }
        return merged.sorted { $0.key < $1.key }.map { entry in
            let totals = entry.value
            return DailyHistorySummary(
                dayStart: Date(timeIntervalSince1970: TimeInterval(entry.key)),
                cpuSeconds: totals.cpuSeconds,
                diskReadBytes: totals.diskReadBytes,
                diskWriteBytes: totals.diskWriteBytes,
                networkReceiveBytes: totals.networkReceiveBytes,
                networkTransmitBytes: totals.networkTransmitBytes,
                sampleCount: totals.sampleCount,
                gaps: totals.gaps,
                counterResets: totals.counterResets)
        }
    }

    public func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] {
        guard lastDays > 0 else { throw MonitoringHistoryError.invalidRequest("lastDays must be positive") }
        let handle = try openDatabase()
        let calendar = dayCalendar.current()
        let lastDay = HistoryDayCalendar.dayStart(containing: date, in: calendar)
        let firstDay = HistoryDayCalendar.dayStart(lastDay, addingDays: -(min(lastDays, 3650) - 1), in: calendar)
        let firstKey = Self.epochKey(firstDay)
        let lastKey = Self.epochKey(lastDay)

        var merged = try readApplicationTotals(from: firstKey, through: lastKey, on: handle.pointer)
        for (key, pending) in pendingApplications where key.dayStart >= firstKey && key.dayStart <= lastKey {
            var entry = merged[key] ?? ApplicationTotals(identity: pending.identity, totals: HistoryTotals())
            entry.identity = pending.identity
            entry.totals.add(pending.totals)
            merged[key] = entry
        }
        return merged.sorted { lhs, rhs in
            if lhs.key.dayStart != rhs.key.dayStart { return lhs.key.dayStart < rhs.key.dayStart }
            let order = Self.caseInsensitiveOrder(lhs.value.identity.name, rhs.value.identity.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.key.applicationID < rhs.key.applicationID
        }.map { entry in
            let value = entry.value
            return ApplicationDailyHistorySummary(
                dayStart: Date(timeIntervalSince1970: TimeInterval(entry.key.dayStart)),
                application: value.identity,
                cpuSeconds: value.totals.cpuSeconds,
                diskReadBytes: value.totals.diskReadBytes,
                diskWriteBytes: value.totals.diskWriteBytes,
                networkReceiveBytes: value.totals.networkReceiveBytes,
                networkTransmitBytes: value.totals.networkTransmitBytes,
                sampleCount: value.totals.sampleCount,
                gaps: value.totals.gaps,
                counterResets: value.totals.counterResets)
        }
    }

    public func reset() async throws {
        let handle = try openDatabase()
        let db = handle.pointer
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            let dataVersion = try readDataVersion(on: handle)
            try execute("DELETE FROM daily_totals", on: db)
            try execute("DELETE FROM application_daily_totals", on: db)
            try execute("DELETE FROM monitoring_state", on: db)
            try execute("DELETE FROM application_sample_state", on: db)
            try execute("DELETE FROM network_measurement_state", on: db)
            let resetAt = Date()
            try saveResetBoundary(resetAt, on: db)
            try execute("COMMIT", on: db)
            discardBuffer()
            priorSample = nil
            priorApplicationSamples.removeAll()
            networkWindows.removeAll()
            networkWindowsLoaded = true
            resetBoundary = resetAt
            collectionStateLoaded = true
            observedDataVersion = dataVersion
        } catch {
            try? execute("ROLLBACK", on: db)
            throw error
        }
    }

    private func openDatabase() throws -> DatabaseHandle {
        if let database { return database }
        guard let databaseURL else {
            throw MonitoringHistoryError.databaseUnavailable("Application Support is unavailable.")
        }
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw MonitoringHistoryError.databaseUnavailable(error.localizedDescription)
        }
        var opened: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &opened,
                                       SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                                       nil)
        guard openCode == SQLITE_OK, let opened else {
            let error = opened.map { sqliteError($0, code: openCode) }
                ?? MonitoringHistoryError.sqlite(code: openCode, message: "Unable to open history database")
            if let opened { sqlite3_close(opened) }
            throw error
        }
        sqlite3_busy_timeout(opened, 1_000)
        // From here the handle owns the connection, so any failure below closes it on release.
        let handle = DatabaseHandle(opened)
        try execute("PRAGMA journal_mode = WAL", on: opened)
        try execute("PRAGMA synchronous = NORMAL", on: opened)
        try migrate(handle)
        database = handle
        return handle
    }

    private func migrate(_ handle: DatabaseHandle) throws {
        let db = handle.pointer
        var statement: OpaquePointer?
        try prepare("PRAGMA user_version", statement: &statement, on: db)
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            sqlite3_finalize(statement)
            throw sqliteError(db, code: step)
        }
        let currentVersion = sqlite3_column_int(statement, 0)
        sqlite3_finalize(statement)
        guard currentVersion <= Self.schemaVersion else {
            throw MonitoringHistoryError.unsupportedSchema(currentVersion)
        }
        if currentVersion == Self.schemaVersion { return }

        let hasExistingTables = try hasAnyHistoryTable(on: db)
        let calendar = dayCalendar.current()
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            if currentVersion == 0 && !hasExistingTables {
                try createCurrentSchema(on: db)
            } else {
                try upgradeLegacySchema(version: currentVersion, on: db)
                // Versions before 6 keyed every day at UTC midnight. Move those rows onto local days.
                try rekeyLegacyDayRows(on: handle, calendar: calendar)
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)", on: db)
            try execute("COMMIT", on: db)
        } catch {
            try? execute("ROLLBACK", on: db)
            throw error
        }
    }

    private func createCurrentSchema(on db: OpaquePointer) throws {
        try execute(Self.dailyTotalsCreateSQL, on: db)
        try execute(Self.applicationDailyTotalsCreateSQL, on: db)
        try execute(Self.monitoringStateCreateSQL, on: db)
        try execute(Self.applicationSampleStateCreateSQL, on: db)
        try createNetworkMeasurementState(on: db)
        try execute(Self.historyResetStateCreateSQL, on: db)
    }

    private func upgradeLegacySchema(version: Int32, on db: OpaquePointer) throws {
        guard try tableExists("daily_totals", on: db) else {
            throw MonitoringHistoryError.unsupportedSchema(version)
        }
        try upgradeTable(
            "daily_totals",
            requiredColumns: ["day_start"],
            addableColumns: [
                ("cpu_seconds", "REAL"),
                ("disk_read_bytes", "INTEGER"),
                ("disk_write_bytes", "INTEGER"),
                ("network_receive_bytes", "INTEGER"),
                ("network_transmit_bytes", "INTEGER"),
                ("sample_count", "INTEGER NOT NULL DEFAULT 0"),
                ("gaps", "INTEGER NOT NULL DEFAULT 0"),
                ("counter_resets", "INTEGER NOT NULL DEFAULT 0")
            ],
            createSQL: Self.dailyTotalsCreateSQL,
            version: version, on: db)
        try upgradeTable(
            "application_daily_totals",
            requiredColumns: ["day_start", "application_id", "application_name"],
            addableColumns: [
                ("executable_path", "TEXT"),
                ("association", "TEXT NOT NULL DEFAULT 'standalone'"),
                ("cpu_seconds", "REAL"),
                ("disk_read_bytes", "INTEGER"),
                ("disk_write_bytes", "INTEGER"),
                ("network_receive_bytes", "INTEGER"),
                ("network_transmit_bytes", "INTEGER"),
                ("sample_count", "INTEGER NOT NULL DEFAULT 0"),
                ("gaps", "INTEGER NOT NULL DEFAULT 0"),
                ("counter_resets", "INTEGER NOT NULL DEFAULT 0")
            ],
            createSQL: Self.applicationDailyTotalsCreateSQL,
            version: version, on: db)
        try upgradeTable(
            "monitoring_state",
            requiredColumns: ["state_id", "last_collection_timestamp", "session_id"],
            addableColumns: [],
            createSQL: Self.monitoringStateCreateSQL,
            version: version, on: db)
        try upgradeTable(
            "application_sample_state",
            requiredColumns: ["application_id", "last_timestamp"],
            addableColumns: [],
            createSQL: Self.applicationSampleStateCreateSQL,
            version: version, on: db)
        try createNetworkMeasurementState(on: db)
        try execute(Self.historyResetStateCreateSQL, on: db)
    }

    /// Re-keys UTC-midnight day rows (schema 5 and older) onto the local day that contains each row's
    /// old day start plus 12 hours. Rows that land on the same local day are merged with the upsert rules.
    private func rekeyLegacyDayRows(on handle: DatabaseHandle, calendar: Calendar) throws {
        let db = handle.pointer
        var dailyRows: [Int64: HistoryTotals] = [:]
        for row in try readAllLegacyDailyRows(on: db) {
            let key = Self.localDayKey(forLegacyDay: row.dayStart, calendar: calendar)
            dailyRows[key, default: HistoryTotals()].add(row.totals)
        }
        try execute("DELETE FROM daily_totals", on: db)
        for (dayStart, totals) in dailyRows.sorted(by: { $0.key < $1.key }) {
            try upsertDaily(dayStart, totals, on: handle)
        }

        var applicationRows: [ApplicationDayKey: ApplicationTotals] = [:]
        // Rows arrive oldest first, so the newest identity wins, as it does for live upserts.
        for row in try readAllLegacyApplicationRows(on: db) {
            let key = ApplicationDayKey(dayStart: Self.localDayKey(forLegacyDay: row.dayStart, calendar: calendar),
                                        applicationID: row.identity.id)
            var entry = applicationRows[key] ?? ApplicationTotals(identity: row.identity, totals: HistoryTotals())
            entry.identity = row.identity
            entry.totals.add(row.totals)
            applicationRows[key] = entry
        }
        try execute("DELETE FROM application_daily_totals", on: db)
        for (key, value) in applicationRows.sorted(by: { ($0.key.dayStart, $0.key.applicationID) < ($1.key.dayStart, $1.key.applicationID) }) {
            try upsertApplication(key, value, on: handle)
        }
    }

    private static func localDayKey(forLegacyDay legacyDay: Int64, calendar: Calendar) -> Int64 {
        let instant = Date(timeIntervalSince1970: TimeInterval(legacyDay) + 43_200)
        return epochKey(HistoryDayCalendar.dayStart(containing: instant, in: calendar))
    }

    private func readAllLegacyDailyRows(on db: OpaquePointer) throws -> [(dayStart: Int64, totals: HistoryTotals)] {
        var statement: OpaquePointer?
        try prepare("SELECT day_start, \(Self.dailyColumns) FROM daily_totals ORDER BY day_start ASC",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        var rows: [(dayStart: Int64, totals: HistoryTotals)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            rows.append((dayStart: sqlite3_column_int64(statement, 0),
                         totals: readTotals(statement, startingAt: 1)))
        }
    }

    private func readAllLegacyApplicationRows(on db: OpaquePointer) throws
        -> [(dayStart: Int64, identity: ApplicationHistoryIdentity, totals: HistoryTotals)] {
        var statement: OpaquePointer?
        try prepare("""
        SELECT day_start, application_id, application_name, executable_path, association, \(Self.dailyColumns)
        FROM application_daily_totals ORDER BY day_start ASC
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        var rows: [(dayStart: Int64, identity: ApplicationHistoryIdentity, totals: HistoryTotals)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            rows.append((dayStart: sqlite3_column_int64(statement, 0),
                         identity: readApplicationIdentity(statement),
                         totals: readTotals(statement, startingAt: 5)))
        }
    }

    private func createNetworkMeasurementState(on db: OpaquePointer) throws {
        try execute(Self.networkMeasurementStateCreateSQL, on: db)
        try execute("CREATE INDEX IF NOT EXISTS network_measurement_state_end_idx " +
                    "ON network_measurement_state(interval_end)", on: db)
    }

    private func upgradeTable(_ table: String, requiredColumns: Set<String>,
                              addableColumns: [(name: String, definition: String)],
                              createSQL: String, version: Int32,
                              on db: OpaquePointer) throws {
        guard try tableExists(table, on: db) else {
            try execute(createSQL, on: db)
            return
        }
        let existingColumns = try columns(of: table, on: db)
        guard requiredColumns.isSubset(of: existingColumns) else {
            throw MonitoringHistoryError.unsupportedSchema(version)
        }
        for column in addableColumns where !existingColumns.contains(column.name) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.definition)", on: db)
        }
    }

    private func hasAnyHistoryTable(on db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("""
        SELECT 1 FROM sqlite_master
        WHERE type = 'table'
          AND name IN ('daily_totals', 'application_daily_totals',
                       'monitoring_state', 'application_sample_state', 'network_measurement_state',
                       'history_reset_state')
        LIMIT 1
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
        return false
    }

    private func tableExists(_ table: String, on db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        bind(table, to: statement, index: 1)
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
        return false
    }

    private func columns(of table: String, on db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        try prepare("PRAGMA table_info(\(table))", statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return columns }
            guard code == SQLITE_ROW, let name = stringColumn(statement, index: 1) else {
                throw sqliteError(db, code: code)
            }
            columns.insert(name.lowercased())
        }
    }

    private func readPriorSample(on db: OpaquePointer) throws -> PriorSample? {
        var statement: OpaquePointer?
        try prepare("SELECT last_collection_timestamp, session_id FROM monitoring_state WHERE state_id = 1",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW,
              let storedSessionID = stringColumn(statement, index: 1) else {
            throw sqliteError(db, code: code)
        }
        return PriorSample(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                           sessionID: storedSessionID)
    }

    private func readDataVersion(on handle: DatabaseHandle) throws -> Int32 {
        let statement = try cachedStatement("PRAGMA data_version", on: handle)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw sqliteError(handle.pointer, code: code) }
        return sqlite3_column_int(statement, 0)
    }

    private func readApplicationSamples(on db: OpaquePointer) throws -> [String: Date] {
        var statement: OpaquePointer?
        try prepare("SELECT application_id, last_timestamp FROM application_sample_state",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        var samples: [String: Date] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return samples }
            guard code == SQLITE_ROW, let key = stringColumn(statement, index: 0) else {
                throw sqliteError(db, code: code)
            }
            samples[key] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
    }

    private func readNetworkWindows(on db: OpaquePointer) throws -> [NetworkMeasurementStream: NetworkStreamWindow] {
        var statement: OpaquePointer?
        try prepare("""
        SELECT scope, application_id, direction, interval_start, interval_end
        FROM network_measurement_state ORDER BY rowid ASC
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        var windows: [NetworkMeasurementStream: NetworkStreamWindow] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return windows }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            guard let scope = stringColumn(statement, index: 0),
                  let applicationID = stringColumn(statement, index: 1),
                  let directionText = stringColumn(statement, index: 2),
                  let direction = NetworkMeasurementDirection(rawValue: directionText) else { continue }
            let stream = NetworkMeasurementStream(scope: scope, applicationID: applicationID, direction: direction)
            let interval = NetworkMeasurementInterval(start: sqlite3_column_double(statement, 3),
                                                      end: sqlite3_column_double(statement, 4))
            _ = windows[stream, default: NetworkStreamWindow()].insert(interval)
        }
    }

    private func readResetBoundary(on db: OpaquePointer) throws -> Date? {
        var statement: OpaquePointer?
        try prepare("SELECT reset_timestamp FROM history_reset_state WHERE state_id = 1",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func saveResetBoundary(_ timestamp: Date, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare("""
        INSERT INTO history_reset_state(state_id, reset_timestamp) VALUES(1, ?)
        ON CONFLICT(state_id) DO UPDATE SET reset_timestamp = excluded.reset_timestamp
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
    }

    private func readDailyTotals(from firstKey: Int64, through lastKey: Int64,
                                 on db: OpaquePointer) throws -> [Int64: HistoryTotals] {
        var statement: OpaquePointer?
        try prepare("SELECT day_start, \(Self.dailyColumns) FROM daily_totals WHERE day_start >= ? AND day_start <= ?",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, firstKey)
        sqlite3_bind_int64(statement, 2, lastKey)
        var totals: [Int64: HistoryTotals] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return totals }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            totals[sqlite3_column_int64(statement, 0)] = readTotals(statement, startingAt: 1)
        }
    }

    private func readApplicationTotals(from firstKey: Int64, through lastKey: Int64,
                                       on db: OpaquePointer) throws -> [ApplicationDayKey: ApplicationTotals] {
        var statement: OpaquePointer?
        try prepare("""
        SELECT day_start, application_id, application_name, executable_path, association, \(Self.dailyColumns)
        FROM application_daily_totals WHERE day_start >= ? AND day_start <= ?
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, firstKey)
        sqlite3_bind_int64(statement, 2, lastKey)
        var totals: [ApplicationDayKey: ApplicationTotals] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return totals }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            let identity = readApplicationIdentity(statement)
            let key = ApplicationDayKey(dayStart: sqlite3_column_int64(statement, 0), applicationID: identity.id)
            totals[key] = ApplicationTotals(identity: identity, totals: readTotals(statement, startingAt: 5))
        }
    }

    /// Reads the eight columns named by `dailyColumns`, beginning at `index`.
    private func readTotals(_ statement: OpaquePointer?, startingAt index: Int32) -> HistoryTotals {
        HistoryTotals(
            cpuSeconds: doubleColumn(statement, index: index),
            diskReadBytes: uintColumn(statement, index: index + 1),
            diskWriteBytes: uintColumn(statement, index: index + 2),
            networkReceiveBytes: uintColumn(statement, index: index + 3),
            networkTransmitBytes: uintColumn(statement, index: index + 4),
            sampleCount: Int(sqlite3_column_int64(statement, index + 5)),
            gaps: Int(sqlite3_column_int64(statement, index + 6)),
            counterResets: Int(sqlite3_column_int64(statement, index + 7)))
    }

    /// Reads identity columns 1 through 4 of a row selected as `day_start, application_id,
    /// application_name, executable_path, association, ...`.
    private func readApplicationIdentity(_ statement: OpaquePointer?) -> ApplicationHistoryIdentity {
        let associationText = stringColumn(statement, index: 4) ?? ProcessGroupAssociation.standalone.rawValue
        return ApplicationHistoryIdentity(
            id: stringColumn(statement, index: 1) ?? "unknown",
            name: stringColumn(statement, index: 2) ?? "Unknown application",
            executablePath: stringColumn(statement, index: 3),
            association: ProcessGroupAssociation(rawValue: associationText) ?? .standalone)
    }

    /// Commits the buffer in one transaction. The buffer is cleared only after COMMIT succeeds.
    private func commitBuffer(on handle: DatabaseHandle) throws {
        let db = handle.pointer
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            if let cutoff = pendingRetentionCutoff {
                try deleteExpiredRows(before: cutoff, on: db)
            }
            for (dayStart, totals) in pendingDaily.sorted(by: { $0.key < $1.key }) {
                try upsertDaily(dayStart, totals, on: handle)
            }
            for (key, value) in pendingApplications.sorted(by: { ($0.key.dayStart, $0.key.applicationID) < ($1.key.dayStart, $1.key.applicationID) }) {
                try upsertApplication(key, value, on: handle)
            }
            // Deletions come first so a trimmed identity that was re-measured is inserted again.
            for record in pendingNetworkDeletes {
                try deleteNetworkRecord(record, on: handle)
            }
            for record in pendingNetworkInserts where networkWindows[record.stream]?.members.contains(record.interval) == true {
                try insertNetworkRecord(record, on: handle)
            }
            try saveCollectionState(on: handle)
            try execute("COMMIT", on: db)
        } catch {
            try? execute("ROLLBACK", on: db)
            throw error
        }
        discardBuffer()
    }

    private func discardBuffer() {
        pendingDaily.removeAll()
        pendingApplications.removeAll()
        pendingNetworkInserts.removeAll()
        pendingNetworkDeletes.removeAll()
        pendingRetentionCutoff = nil
        hasUnflushedChanges = false
        flushDeadline = nil
    }

    /// Drops buffered rows and remembered identities that retention would delete anyway.
    private func discardBufferedRows(before cutoff: Date) {
        let cutoffKey = Self.epochKey(cutoff)
        pendingDaily = pendingDaily.filter { $0.key >= cutoffKey }
        pendingApplications = pendingApplications.filter { $0.key.dayStart >= cutoffKey }
        let seconds = cutoff.timeIntervalSince1970
        for stream in Array(networkWindows.keys) {
            networkWindows[stream]?.prune(endingBefore: seconds)
        }
    }

    private func saveCollectionState(on handle: DatabaseHandle) throws {
        if let priorSample {
            let state = try cachedStatement(Self.monitoringStateUpsertSQL, on: handle)
            sqlite3_bind_double(state, 1, priorSample.timestamp.timeIntervalSince1970)
            bind(priorSample.sessionID, to: state, index: 2)
            let code = sqlite3_step(state)
            guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
        }
        try execute("DELETE FROM application_sample_state", on: handle.pointer)
        let upsert = try cachedStatement(Self.applicationSampleUpsertSQL, on: handle)
        for (applicationID, sampleTime) in priorApplicationSamples.sorted(by: { $0.key < $1.key }) {
            bind(applicationID, to: upsert, index: 1)
            sqlite3_bind_double(upsert, 2, sampleTime.timeIntervalSince1970)
            let code = sqlite3_step(upsert)
            guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
        }
    }

    /// Returns a prepared statement for `sql`, preparing it on first use and reusing it afterwards.
    private func cachedStatement(_ sql: String, on handle: DatabaseHandle) throws -> OpaquePointer {
        if let cached = handle.statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle.pointer, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw sqliteError(handle.pointer, code: code) }
        handle.statements[sql] = statement
        return statement
    }

    private func upsertDaily(_ dayStart: Int64, _ totals: HistoryTotals, on handle: DatabaseHandle) throws {
        let statement = try cachedStatement(Self.dailyUpsertSQL, on: handle)
        sqlite3_bind_int64(statement, 1, dayStart)
        bind(totals.cpuSeconds, to: statement, index: 2)
        bind(totals.diskReadBytes, to: statement, index: 3)
        bind(totals.diskWriteBytes, to: statement, index: 4)
        bind(totals.networkReceiveBytes, to: statement, index: 5)
        bind(totals.networkTransmitBytes, to: statement, index: 6)
        sqlite3_bind_int64(statement, 7, Int64(totals.sampleCount))
        sqlite3_bind_int64(statement, 8, Int64(totals.gaps))
        sqlite3_bind_int64(statement, 9, Int64(totals.counterResets))
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
    }

    private func upsertApplication(_ key: ApplicationDayKey, _ value: ApplicationTotals,
                                   on handle: DatabaseHandle) throws {
        let statement = try cachedStatement(Self.applicationUpsertSQL, on: handle)
        sqlite3_bind_int64(statement, 1, key.dayStart)
        bind(value.identity.id, to: statement, index: 2)
        bind(value.identity.name, to: statement, index: 3)
        bind(value.identity.executablePath, to: statement, index: 4)
        bind(value.identity.association.rawValue, to: statement, index: 5)
        bind(value.totals.cpuSeconds, to: statement, index: 6)
        bind(value.totals.diskReadBytes, to: statement, index: 7)
        bind(value.totals.diskWriteBytes, to: statement, index: 8)
        bind(value.totals.networkReceiveBytes, to: statement, index: 9)
        bind(value.totals.networkTransmitBytes, to: statement, index: 10)
        sqlite3_bind_int64(statement, 11, Int64(value.totals.sampleCount))
        sqlite3_bind_int64(statement, 12, Int64(value.totals.gaps))
        sqlite3_bind_int64(statement, 13, Int64(value.totals.counterResets))
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
    }

    private func insertNetworkRecord(_ record: NetworkMeasurementRecord, on handle: DatabaseHandle) throws {
        let statement = try cachedStatement(Self.networkInsertSQL, on: handle)
        bind(record.stream.scope, to: statement, index: 1)
        bind(record.stream.applicationID, to: statement, index: 2)
        bind(record.stream.direction.rawValue, to: statement, index: 3)
        sqlite3_bind_double(statement, 4, record.interval.start)
        sqlite3_bind_double(statement, 5, record.interval.end)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
    }

    private func deleteNetworkRecord(_ record: NetworkMeasurementRecord, on handle: DatabaseHandle) throws {
        let statement = try cachedStatement(Self.networkDeleteSQL, on: handle)
        bind(record.stream.scope, to: statement, index: 1)
        bind(record.stream.applicationID, to: statement, index: 2)
        bind(record.stream.direction.rawValue, to: statement, index: 3)
        sqlite3_bind_double(statement, 4, record.interval.start)
        sqlite3_bind_double(statement, 5, record.interval.end)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(handle.pointer, code: code) }
    }

    /// Network measurement identity is checked in memory. Inserts and trims are buffered until commit.
    private func rateTotal(_ reading: MetricReading, fallbackInterval: DateInterval?,
                           cutoff: Date, stream: NetworkMeasurementStream) -> NetworkRateTotal {
        guard let rate = reading.value else { return NetworkRateTotal(bytes: nil, interval: nil) }
        if let measured = reading.measurementInterval {
            guard Self.isValid(measured), measured.end > cutoff else {
                return NetworkRateTotal(bytes: nil, interval: nil)
            }
            // Intervals that began before the last reset belong to traffic already discarded by reset().
            if let resetBoundary, measured.start < resetBoundary {
                return NetworkRateTotal(bytes: nil, interval: nil)
            }
            guard rememberNetworkMeasurement(measured, stream: stream) else {
                return NetworkRateTotal(bytes: nil, interval: nil)
            }
            return NetworkRateTotal(bytes: Self.byteTotal(rate * measured.duration), interval: measured)
        }
        guard !reading.isPartial else { return NetworkRateTotal(bytes: nil, interval: nil) }
        guard let fallbackInterval, Self.isValid(fallbackInterval) else {
            return NetworkRateTotal(bytes: nil, interval: nil)
        }
        return NetworkRateTotal(bytes: Self.byteTotal(rate * fallbackInterval.duration), interval: fallbackInterval)
    }

    /// Returns false when this identity was already counted. Trims the stream to its bound.
    private func rememberNetworkMeasurement(_ interval: DateInterval, stream: NetworkMeasurementStream) -> Bool {
        let measured = NetworkMeasurementInterval(start: interval.start.timeIntervalSince1970,
                                                  end: interval.end.timeIntervalSince1970)
        var window = networkWindows.removeValue(forKey: stream) ?? NetworkStreamWindow()
        defer { networkWindows[stream] = window }
        guard window.insert(measured) else { return false }
        pendingNetworkInserts.append(NetworkMeasurementRecord(stream: stream, interval: measured))
        while window.count > Self.maximumRememberedMeasurementIntervalsPerStream,
              let evicted = window.removeOldest() {
            pendingNetworkDeletes.insert(NetworkMeasurementRecord(stream: stream, interval: evicted))
        }
        return true
    }

    private func deleteExpiredRows(before cutoff: Date, on db: OpaquePointer) throws {
        let cutoffDay = Self.epochKey(cutoff)
        for sql in ["DELETE FROM daily_totals WHERE day_start < ?",
                    "DELETE FROM application_daily_totals WHERE day_start < ?"] {
            var statement: OpaquePointer?
            try prepare(sql, statement: &statement, on: db)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, cutoffDay)
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
        }
        try deleteExpiredNetworkMeasurements(before: cutoff, on: db)
    }

    private func deleteExpiredNetworkMeasurements(before cutoff: Date, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM network_measurement_state WHERE interval_end < ?",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
    }

    private static func isValid(_ interval: DateInterval) -> Bool {
        let duration = interval.duration
        return duration.isFinite && duration > 0 && duration <= 30
    }

    private static func epochKey(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    /// Case-insensitive ordering that folds ASCII only, matching SQLite's NOCASE collation.
    private static func caseInsensitiveOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func folded(_ text: String) -> [UInt8] {
            text.utf8.map { byte in (byte >= 65 && byte <= 90) ? byte + 32 : byte }
        }
        let left = folded(lhs)
        let right = folded(rhs)
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    /// Gaps mark readings that should have been measured but were lost to a collection or permission
    /// failure, or only partly measured. Sleep, pause, relaunch, and new applications are not gaps.
    private static func hasMeasurementGap(_ readings: [MetricReading]) -> Bool {
        readings.contains { reading in
            if reading.unavailableReason == .collectionFailed || reading.unavailableReason == .permissionDenied {
                return true
            }
            return reading.isAvailable && reading.isPartial
        }
    }

    private func dailyTotals(from start: Date?, through end: Date, cpuSeconds: Double?, diskRead: UInt64?,
                             diskWrite: UInt64?, networkReceive: UInt64?, networkTransmit: UInt64?,
                             gaps: Int, counterResets: Int, sampleCount: Int = 1,
                             calendar: Calendar) -> [DayTotals] {
        guard let start, end > start else {
            return [DayTotals(
                dayStart: HistoryDayCalendar.dayStart(containing: end, in: calendar),
                totals: HistoryTotals(sampleCount: sampleCount, gaps: gaps, counterResets: counterResets))]
        }

        let elapsed = end.timeIntervalSince(start)
        let pieces = dayPieces(from: start, through: end, calendar: calendar)
        let cpuAmounts = distribute(cpuSeconds, across: pieces, over: elapsed)
        let readAmounts = distribute(diskRead, across: pieces, over: elapsed)
        let writeAmounts = distribute(diskWrite, across: pieces, over: elapsed)
        let receiveAmounts = distribute(networkReceive, across: pieces, over: elapsed)
        let transmitAmounts = distribute(networkTransmit, across: pieces, over: elapsed)
        return pieces.indices.map { index in
            let isEndpointDay = index == pieces.count - 1
            return DayTotals(
                dayStart: pieces[index].dayStart,
                totals: HistoryTotals(
                    cpuSeconds: cpuAmounts[index], diskReadBytes: readAmounts[index],
                    diskWriteBytes: writeAmounts[index], networkReceiveBytes: receiveAmounts[index],
                    networkTransmitBytes: transmitAmounts[index],
                    sampleCount: isEndpointDay ? sampleCount : 0,
                    gaps: isEndpointDay ? gaps : 0,
                    counterResets: isEndpointDay ? counterResets : 0))
        }
    }

    /// Slices an interval at real local midnights. The endpoint day is always present, last, and may be empty.
    private func dayPieces(from start: Date, through end: Date, calendar: Calendar) -> [DayPiece] {
        var pieces: [DayPiece] = []
        var cursor = start
        while cursor < end {
            let dayStart = HistoryDayCalendar.dayStart(containing: cursor, in: calendar)
            let nextDay = HistoryDayCalendar.dayStart(dayStart, addingDays: 1, in: calendar)
            let segmentEnd = nextDay > cursor ? min(end, nextDay) : end
            pieces.append(DayPiece(dayStart: dayStart, duration: segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        let endpointDay = HistoryDayCalendar.dayStart(containing: end, in: calendar)
        if pieces.last?.dayStart != endpointDay {
            pieces.append(DayPiece(dayStart: endpointDay, duration: 0))
        }
        return pieces
    }

    private func distribute(_ total: Double?, across pieces: [DayPiece],
                            over elapsed: TimeInterval) -> [Double?] {
        guard let total else { return Array(repeating: nil, count: pieces.count) }
        var allocated = 0.0
        return pieces.indices.map { index -> Double? in
            if index == pieces.count - 1 { return max(0, total - allocated) }
            let amount = min(max(0, total - allocated), total * pieces[index].duration / elapsed)
            allocated += amount
            return amount
        }
    }

    private func distribute(_ total: UInt64?, across pieces: [DayPiece],
                            over elapsed: TimeInterval) -> [UInt64?] {
        guard let total else { return Array(repeating: nil, count: pieces.count) }
        var allocated: UInt64 = 0
        return pieces.indices.map { index -> UInt64? in
            if index == pieces.count - 1 { return total - allocated }
            let share = (Double(total) * pieces[index].duration / elapsed).rounded(.down)
            let amount = min(total - allocated, UInt64(max(0, share)))
            allocated += amount
            return amount
        }
    }

    private func recordApplicationTotals(snapshot: MonitoringSnapshot, cutoff: Date,
                                         previousSamples: [String: Date], sameSession: Bool,
                                         calendar: Calendar) -> [String: Date] {
        var seenProcesses = Set<ProcessIdentity>()
        var grouped: [String: (identity: ApplicationHistoryIdentity, cpu: [MetricReading],
                               read: [MetricReading], write: [MetricReading],
                               receive: [MetricReading], transmit: [MetricReading])] = [:]
        let currentUID = UInt32(getuid())

        for group in snapshot.processGroups.sorted(by: { $0.historyIdentity.id < $1.historyIdentity.id }) {
            guard group.ownerUID == currentUID, !group.members.isEmpty else { continue }
            guard group.members.allSatisfy({ !seenProcesses.contains($0) }) else { continue }
            seenProcesses.formUnion(group.members)
            let key = group.historyIdentity.id
            if grouped[key] == nil {
                grouped[key] = (group.historyIdentity, [], [], [], [], [])
            }
            grouped[key]?.cpu.append(group.cpuPercent)
            grouped[key]?.read.append(group.diskReadBytesPerSecond)
            grouped[key]?.write.append(group.diskWriteBytesPerSecond)
            grouped[key]?.receive.append(group.networkReceiveBytesPerSecond)
            grouped[key]?.transmit.append(group.networkTransmitBytesPerSecond)
        }

        var currentApplicationSamples: [String: Date] = [:]
        let ordered = grouped.values.sorted { $0.identity.id < $1.identity.id }
        for value in ordered {
            let identity = value.identity
            let key = identity.id
            let cpu = combine(value.cpu, unit: .percent, timestamp: snapshot.timestamp)
            let read = combine(value.read, unit: .bytesPerSecond, timestamp: snapshot.timestamp)
            let write = combine(value.write, unit: .bytesPerSecond, timestamp: snapshot.timestamp)
            let receive = combine(value.receive, unit: .bytesPerSecond, timestamp: snapshot.timestamp)
            let transmit = combine(value.transmit, unit: .bytesPerSecond, timestamp: snapshot.timestamp)
            let previous = previousSamples[key]
            let elapsed: TimeInterval?
            if sameSession, let previous {
                let duration = snapshot.timestamp.timeIntervalSince(previous)
                elapsed = duration > 0 && duration <= Self.maximumIntegratedInterval ? duration : nil
            } else {
                elapsed = nil
            }
            let readings = [cpu, read, write, receive, transmit]
            let sourceReadings = value.cpu + value.read + value.write + value.receive + value.transmit
            let hasSleepGap = sourceReadings.contains { $0.unavailableReason == .sleepGap }
            let interval = hasSleepGap ? nil : elapsed
            let applicationInterval = interval.flatMap { _ in
                previous.map { DateInterval(start: $0, end: snapshot.timestamp) }
            }
            let networkReceive = rateTotal(receive, fallbackInterval: applicationInterval, cutoff: cutoff,
                                           stream: .application(key, .receive))
            let networkTransmit = rateTotal(transmit, fallbackInterval: applicationInterval, cutoff: cutoff,
                                            stream: .application(key, .transmit))
            let gap = Self.hasMeasurementGap(readings)
            let reset = sourceReadings.contains { $0.unavailableReason == .counterReset }
            let cpuSeconds = cpu.value.flatMap { value in
                interval.map { max(0, value) / 100 * Double(max(1, snapshot.system.capacityCores)) * $0 }
            }
            let readBytes = read.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            let writeBytes = write.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            var totals = dailyTotals(
                from: applicationInterval?.start, through: snapshot.timestamp,
                cpuSeconds: cpuSeconds, diskRead: readBytes, diskWrite: writeBytes,
                networkReceive: nil, networkTransmit: nil,
                gaps: gap ? 1 : 0, counterResets: reset ? 1 : 0, calendar: calendar)
            totals += dailyTotals(
                from: networkReceive.interval?.start, through: networkReceive.interval?.end ?? snapshot.timestamp,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: networkReceive.bytes, networkTransmit: nil,
                gaps: 0, counterResets: 0, sampleCount: 0, calendar: calendar)
            totals += dailyTotals(
                from: networkTransmit.interval?.start, through: networkTransmit.interval?.end ?? snapshot.timestamp,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: nil, networkTransmit: networkTransmit.bytes,
                gaps: 0, counterResets: 0, sampleCount: 0, calendar: calendar)
            for daily in totals where daily.dayStart >= cutoff {
                let dayKey = ApplicationDayKey(dayStart: Self.epochKey(daily.dayStart), applicationID: identity.id)
                var entry = pendingApplications[dayKey] ?? ApplicationTotals(identity: identity, totals: HistoryTotals())
                entry.identity = identity
                entry.totals.add(daily.totals)
                pendingApplications[dayKey] = entry
            }
            currentApplicationSamples[key] = snapshot.timestamp
        }
        return currentApplicationSamples
    }

    private func combine(_ readings: [MetricReading], unit: MetricUnit, timestamp: Date) -> MetricReading {
        guard !readings.isEmpty else {
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .notCollected)
        }
        let unavailableCount = readings.filter { !$0.isAvailable }.count
        let availableValues = readings.compactMap(\.value)
        let hasIncompatibleIntervals = hasIncompatibleMeasurementIntervals(readings)
        let isPartial = readings.contains(where: \.isPartial) || hasIncompatibleIntervals
            || (!availableValues.isEmpty && unavailableCount > 0)
        guard !availableValues.isEmpty else {
            let unavailable = readings.first(where: { !$0.isAvailable })
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: unavailable?.unavailableReason ?? .collectionFailed,
                                 detail: unavailable?.detail, isPartial: isPartial)
        }
        var details = readings.compactMap(\.detail)
        if unavailableCount > 0 {
            details.append("Partial: \(unavailableCount) of \(readings.count) members unavailable")
        }
        if hasIncompatibleIntervals {
            details.append("Measurement intervals differ across contributors")
        }
        var seenDetails = Set<String>()
        let detail = details.filter { seenDetails.insert($0).inserted }.joined(separator: "; ")
        let measurementInterval = commonMeasurementInterval(readings)
        return MetricReading(value: availableValues.reduce(0, +), unit: unit,
                             timestamp: measurementInterval?.end ?? timestamp,
                             detail: detail.isEmpty ? nil : detail, isPartial: isPartial,
                             measurementInterval: measurementInterval)
    }

    private func commonMeasurementInterval(_ readings: [MetricReading]) -> DateInterval? {
        let available = readings.filter(\.isAvailable)
        guard let interval = available.first?.measurementInterval,
              available.allSatisfy({ $0.measurementInterval == interval }) else { return nil }
        return interval
    }

    private func hasIncompatibleMeasurementIntervals(_ readings: [MetricReading]) -> Bool {
        let available = readings.filter(\.isAvailable)
        let intervals = available.compactMap(\.measurementInterval)
        guard !intervals.isEmpty else { return false }
        return intervals.count != available.count || intervals.contains { $0 != intervals[0] }
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard code == SQLITE_OK else {
            throw MonitoringHistoryError.sqlite(code: code,
                                                message: message.map { String(cString: $0) }
                                                    ?? String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?, on db: OpaquePointer) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw sqliteError(db, code: code) }
    }

    private func sqliteError(_ db: OpaquePointer, code: Int32) -> MonitoringHistoryError {
        MonitoringHistoryError.sqlite(code: code, message: String(cString: sqlite3_errmsg(db)))
    }

    private func bind(_ value: Double?, to statement: OpaquePointer?, index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: UInt64?, to statement: OpaquePointer?, index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, Int64(min(value, UInt64(Int64.max)))) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value {
            // SQLITE_TRANSIENT (-1): SQLite copies the string before sqlite3_bind_text returns.
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, index, value, -1, transient)
        }
        else { sqlite3_bind_null(statement, index) }
    }

    private func doubleColumn(_ statement: OpaquePointer?, index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func uintColumn(_ statement: OpaquePointer?, index: Int32) -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else { return nil }
        return UInt64(value)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func byteTotal(_ rateTimesSeconds: Double) -> UInt64 {
        guard rateTimesSeconds.isFinite, rateTimesSeconds > 0 else { return 0 }
        return UInt64(min(rateTimesSeconds.rounded(.down), Double(Int64.max)))
    }

    private static func defaultDatabaseURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first else { return nil }
        return supportDirectory.appendingPathComponent(Bundle.main.bundleIdentifier ?? "run.rosie.microgravity",
                                                       isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
    }
}

private extension MonitoringSnapshot {
    var allSystemReadings: [MetricReading] {
        let system = self.system
        return [system.cpuPercent, system.memoryUsedBytes, system.memoryAvailableBytes, system.memoryTotalBytes,
                system.swapUsedBytes, system.swapTotalBytes, system.diskReadBytesPerSecond,
                system.diskWriteBytesPerSecond, system.networkReceiveBytesPerSecond,
                system.networkTransmitBytesPerSecond] + system.perCoreCPUPercent
            + system.networkInterfaces.flatMap { [$0.receiveBytesPerSecond, $0.transmitBytesPerSecond] }
    }

    /// Readings that feed system history totals. Gaps are judged only on these.
    var systemMeasuredReadings: [MetricReading] {
        [system.cpuPercent, system.diskReadBytesPerSecond, system.diskWriteBytesPerSecond,
         system.networkReceiveBytesPerSecond, system.networkTransmitBytesPerSecond]
    }
}
