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

/// Stores only daily aggregate totals. System history deliberately excludes
/// process names, command lines, paths, and destination values. Application
/// history stores application display names and executable bundle paths so
/// per-application totals can be attributed and presented.
public actor SQLiteMonitoringHistoryStore: MonitoringHistoryManaging {
    public static let schemaVersion: Int32 = 5
    public static let retentionDays = 30
    static let maximumRememberedMeasurementIntervalsPerStream = 128

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

    private struct PriorSample: Equatable {
        let timestamp: Date
        let sessionID: String
    }

    private let databaseURL: URL?
    private let sessionID = UUID().uuidString
    private var database: OpaquePointer?
    private var priorSample: PriorSample?
    private var priorApplicationSamples: [String: Date] = [:]
    private var collectionStateLoaded = false
    private var observedDataVersion: Int32?
    private var resetBoundary: Date?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func record(snapshot: MonitoringSnapshot) async throws {
        let db = try openDatabase()
        let now = snapshot.timestamp
        let today = utcDayStart(now)
        let cutoff = today.addingTimeInterval(-Double(Self.retentionDays - 1) * 86_400)
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            try execute("DELETE FROM daily_totals WHERE day_start < \(Int64(cutoff.timeIntervalSince1970))", on: db)
            try execute("DELETE FROM application_daily_totals WHERE day_start < \(Int64(cutoff.timeIntervalSince1970))", on: db)
            try deleteExpiredNetworkMeasurements(before: cutoff, on: db)

            let dataVersion = try readDataVersion(on: db)
            if !collectionStateLoaded || observedDataVersion != dataVersion {
                priorSample = try readPriorSample(on: db)
                priorApplicationSamples = try readApplicationSamples(on: db)
                resetBoundary = try readResetBoundary(on: db)
                collectionStateLoaded = true
                observedDataVersion = dataVersion
            }
            let prior = priorSample
            let priorApplications = priorApplicationSamples
            let sameSession = prior?.sessionID == sessionID
            let hasExistingTotals: Bool
            if prior == nil { hasExistingTotals = try containsStoredTotals(on: db) }
            else { hasExistingTotals = false }
            let elapsed: TimeInterval?
            if sameSession, let prior {
                let gap = now.timeIntervalSince(prior.timestamp)
                elapsed = gap > 0 && gap <= 30 ? gap : nil
            } else {
                elapsed = nil
            }
            let hasSleepGap = snapshot.allSystemReadings.contains { $0.unavailableReason == .sleepGap }
            let hasGap = prior != nil && (!sameSession || elapsed == nil)
                || hasExistingTotals
                || snapshot.allSystemReadings.contains {
                    Self.isIncomplete($0.unavailableReason) || ($0.isAvailable && $0.isPartial)
                }
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
            let networkReceive = try rateTotal(snapshot.system.networkReceiveBytesPerSecond,
                                               fallbackInterval: historyInterval, cutoff: cutoff,
                                               stream: .system(.receive), on: db)
            let networkTransmit = try rateTotal(snapshot.system.networkTransmitBytesPerSecond,
                                                fallbackInterval: historyInterval, cutoff: cutoff,
                                                stream: .system(.transmit), on: db)

            var systemTotals = dailyTotals(
                from: historyInterval?.start, through: now,
                cpuSeconds: cpuSeconds, diskRead: diskRead, diskWrite: diskWrite,
                networkReceive: nil, networkTransmit: nil,
                gaps: hasGap ? 1 : 0, counterResets: hasCounterReset ? 1 : 0)
            systemTotals += dailyTotals(
                from: networkReceive.interval?.start, through: networkReceive.interval?.end ?? now,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: networkReceive.bytes, networkTransmit: nil,
                gaps: 0, counterResets: 0, sampleCount: 0)
            systemTotals += dailyTotals(
                from: networkTransmit.interval?.start, through: networkTransmit.interval?.end ?? now,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: nil, networkTransmit: networkTransmit.bytes,
                gaps: 0, counterResets: 0, sampleCount: 0)
            for totals in systemTotals where totals.dayStart >= cutoff {
                try upsert(totals, on: db)
            }
            let currentApplicationSamples = try recordApplicationTotals(
                snapshot: snapshot, cutoff: cutoff, previousSamples: priorApplications,
                sameSession: sameSession,
                hasExistingTotals: hasExistingTotals, on: db)
            try saveCollectionState(timestamp: now, applicationSamples: currentApplicationSamples,
                                    previousApplicationSamples: priorApplications, on: db)
            try execute("COMMIT", on: db)
            priorSample = PriorSample(timestamp: now, sessionID: sessionID)
            priorApplicationSamples = currentApplicationSamples
            collectionStateLoaded = true
            observedDataVersion = dataVersion
        } catch {
            try? execute("ROLLBACK", on: db)
            throw error
        }
    }

    public func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary] {
        guard lastDays > 0 else { throw MonitoringHistoryError.invalidRequest("lastDays must be positive") }
        let db = try openDatabase()
        let lastDay = utcDayStart(date)
        let firstDay = lastDay.addingTimeInterval(-Double(min(lastDays, 3650) - 1) * 86_400)
        let sql = """
        SELECT day_start, cpu_seconds, disk_read_bytes, disk_write_bytes,
               network_receive_bytes, network_transmit_bytes, sample_count, gaps, counter_resets
        FROM daily_totals
        WHERE day_start >= ? AND day_start <= ?
        ORDER BY day_start ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(firstDay.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(lastDay.timeIntervalSince1970))

        var results: [DailyHistorySummary] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            results.append(DailyHistorySummary(
                dayStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                cpuSeconds: doubleColumn(statement, index: 1),
                diskReadBytes: uintColumn(statement, index: 2),
                diskWriteBytes: uintColumn(statement, index: 3),
                networkReceiveBytes: uintColumn(statement, index: 4),
                networkTransmitBytes: uintColumn(statement, index: 5),
                sampleCount: Int(sqlite3_column_int64(statement, 6)),
                gaps: Int(sqlite3_column_int64(statement, 7)),
                counterResets: Int(sqlite3_column_int64(statement, 8))))
        }
        return results
    }

    public func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary] {
        guard lastDays > 0 else { throw MonitoringHistoryError.invalidRequest("lastDays must be positive") }
        let db = try openDatabase()
        let lastDay = utcDayStart(date)
        let firstDay = lastDay.addingTimeInterval(-Double(min(lastDays, 3650) - 1) * 86_400)
        let sql = """
        SELECT day_start, application_id, application_name, executable_path, association,
               cpu_seconds, disk_read_bytes, disk_write_bytes, network_receive_bytes,
               network_transmit_bytes, sample_count, gaps, counter_resets
        FROM application_daily_totals
        WHERE day_start >= ? AND day_start <= ?
        ORDER BY day_start ASC, application_name COLLATE NOCASE ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(firstDay.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(lastDay.timeIntervalSince1970))

        var results: [ApplicationDailyHistorySummary] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
            let associationText = stringColumn(statement, index: 4) ?? ProcessGroupAssociation.standalone.rawValue
            let association = ProcessGroupAssociation(rawValue: associationText) ?? .standalone
            let identity = ApplicationHistoryIdentity(
                id: stringColumn(statement, index: 1) ?? "unknown",
                name: stringColumn(statement, index: 2) ?? "Unknown application",
                executablePath: stringColumn(statement, index: 3), association: association)
            results.append(ApplicationDailyHistorySummary(
                dayStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                application: identity,
                cpuSeconds: doubleColumn(statement, index: 5),
                diskReadBytes: uintColumn(statement, index: 6),
                diskWriteBytes: uintColumn(statement, index: 7),
                networkReceiveBytes: uintColumn(statement, index: 8),
                networkTransmitBytes: uintColumn(statement, index: 9),
                sampleCount: Int(sqlite3_column_int64(statement, 10)),
                gaps: Int(sqlite3_column_int64(statement, 11)),
                counterResets: Int(sqlite3_column_int64(statement, 12))))
        }
        return results
    }

    public func reset() async throws {
        let db = try openDatabase()
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            let dataVersion = try readDataVersion(on: db)
            try execute("DELETE FROM daily_totals", on: db)
            try execute("DELETE FROM application_daily_totals", on: db)
            try execute("DELETE FROM monitoring_state", on: db)
            try execute("DELETE FROM application_sample_state", on: db)
            try execute("DELETE FROM network_measurement_state", on: db)
            let resetAt = Date()
            try saveResetBoundary(resetAt, on: db)
            try execute("COMMIT", on: db)
            priorSample = nil
            priorApplicationSamples.removeAll()
            resetBoundary = resetAt
            collectionStateLoaded = true
            observedDataVersion = dataVersion
        } catch {
            try? execute("ROLLBACK", on: db)
            throw error
        }
    }

    private func openDatabase() throws -> OpaquePointer {
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
        do {
            try execute("PRAGMA journal_mode = WAL", on: opened)
            try execute("PRAGMA synchronous = NORMAL", on: opened)
            try migrate(opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        database = opened
        return opened
    }

    private func migrate(_ db: OpaquePointer) throws {
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
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            if currentVersion == 0 && !hasExistingTables {
                try createCurrentSchema(on: db)
            } else {
                try upgradeLegacySchema(version: currentVersion, on: db)
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

    private func readDataVersion(on db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        try prepare("PRAGMA data_version", statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
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

    private func containsStoredTotals(on db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("SELECT EXISTS(SELECT 1 FROM daily_totals UNION ALL SELECT 1 FROM application_daily_totals)",
                    statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw sqliteError(db, code: code) }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func saveCollectionState(timestamp: Date, applicationSamples: [String: Date],
                                     previousApplicationSamples: [String: Date],
                                     on db: OpaquePointer) throws {
        var state: OpaquePointer?
        try prepare("""
        INSERT INTO monitoring_state(state_id, last_collection_timestamp, session_id)
        VALUES(1, ?, ?)
        ON CONFLICT(state_id) DO UPDATE SET
            last_collection_timestamp = excluded.last_collection_timestamp,
            session_id = excluded.session_id
        """, statement: &state, on: db)
        defer { sqlite3_finalize(state) }
        sqlite3_bind_double(state, 1, timestamp.timeIntervalSince1970)
        bind(sessionID, to: state, index: 2)
        let stateCode = sqlite3_step(state)
        guard stateCode == SQLITE_DONE else { throw sqliteError(db, code: stateCode) }

        let upsert = """
        INSERT INTO application_sample_state(application_id, last_timestamp) VALUES(?, ?)
        ON CONFLICT(application_id) DO UPDATE SET last_timestamp = excluded.last_timestamp
        """
        var upsertStatement: OpaquePointer?
        try prepare(upsert, statement: &upsertStatement, on: db)
        defer { sqlite3_finalize(upsertStatement) }
        for (applicationID, sampleTime) in applicationSamples.sorted(by: { $0.key < $1.key }) {
            bind(applicationID, to: upsertStatement, index: 1)
            sqlite3_bind_double(upsertStatement, 2, sampleTime.timeIntervalSince1970)
            let code = sqlite3_step(upsertStatement)
            guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
            sqlite3_reset(upsertStatement)
        }

        var deleteStatement: OpaquePointer?
        try prepare("DELETE FROM application_sample_state WHERE application_id = ?",
                    statement: &deleteStatement, on: db)
        defer { sqlite3_finalize(deleteStatement) }
        for applicationID in previousApplicationSamples.keys where applicationSamples[applicationID] == nil {
            bind(applicationID, to: deleteStatement, index: 1)
            let code = sqlite3_step(deleteStatement)
            guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
            sqlite3_reset(deleteStatement)
        }
    }

    private struct DailyIntervalSlice {
        let dayStart: Date
        let duration: TimeInterval
    }

    private struct DailyIntervalTotals {
        let dayStart: Date
        let cpuSeconds: Double?
        let diskRead: UInt64?
        let diskWrite: UInt64?
        let networkReceive: UInt64?
        let networkTransmit: UInt64?
        let sampleCount: Int
        let gaps: Int
        let counterResets: Int
    }

    private struct NetworkRateTotal {
        let bytes: UInt64?
        let interval: DateInterval?
    }

    private enum NetworkMeasurementDirection: String {
        case receive
        case transmit
    }

    private struct NetworkMeasurementStream {
        let scope: String
        let applicationID: String
        let direction: NetworkMeasurementDirection

        static func system(_ direction: NetworkMeasurementDirection) -> NetworkMeasurementStream {
            NetworkMeasurementStream(scope: "system", applicationID: "", direction: direction)
        }

        static func application(_ applicationID: String,
                                _ direction: NetworkMeasurementDirection) -> NetworkMeasurementStream {
            NetworkMeasurementStream(scope: "application", applicationID: applicationID,
                                     direction: direction)
        }
    }

    private func rateTotal(_ reading: MetricReading, fallbackInterval: DateInterval?,
                           cutoff: Date, stream: NetworkMeasurementStream,
                           on db: OpaquePointer) throws -> NetworkRateTotal {
        guard let rate = reading.value else { return NetworkRateTotal(bytes: nil, interval: nil) }
        if let measured = reading.measurementInterval {
            guard Self.isValid(measured), measured.end > cutoff else {
                return NetworkRateTotal(bytes: nil, interval: nil)
            }
            // Intervals that began before the last reset belong to traffic already discarded by reset().
            if let resetBoundary, measured.start < resetBoundary {
                return NetworkRateTotal(bytes: nil, interval: nil)
            }
            guard try rememberNetworkMeasurement(measured, stream: stream, on: db) else {
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

    private func rememberNetworkMeasurement(_ interval: DateInterval, stream: NetworkMeasurementStream,
                                            on db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        try prepare("""
        INSERT OR IGNORE INTO network_measurement_state(
            scope, application_id, direction, interval_start, interval_end
        ) VALUES (?, ?, ?, ?, ?)
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        bind(stream.scope, to: statement, index: 1)
        bind(stream.applicationID, to: statement, index: 2)
        bind(stream.direction.rawValue, to: statement, index: 3)
        sqlite3_bind_double(statement, 4, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, interval.end.timeIntervalSince1970)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
        guard sqlite3_changes(db) == 1 else { return false }
        try trimNetworkMeasurements(for: stream, on: db)
        return true
    }

    private func trimNetworkMeasurements(for stream: NetworkMeasurementStream, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        try prepare("""
        DELETE FROM network_measurement_state
        WHERE rowid IN (
            SELECT rowid FROM network_measurement_state
            WHERE scope = ? AND application_id = ? AND direction = ?
            ORDER BY rowid DESC LIMIT -1 OFFSET ?
        )
        """, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        bind(stream.scope, to: statement, index: 1)
        bind(stream.applicationID, to: statement, index: 2)
        bind(stream.direction.rawValue, to: statement, index: 3)
        sqlite3_bind_int64(statement, 4, Int64(Self.maximumRememberedMeasurementIntervalsPerStream))
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
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

    private static func isIncomplete(_ reason: MetricUnavailableReason?) -> Bool {
        reason == .sleepGap || reason == .collectionFailed || reason == .permissionDenied
    }

    private func dailyTotals(from start: Date?, through end: Date, cpuSeconds: Double?, diskRead: UInt64?,
                             diskWrite: UInt64?, networkReceive: UInt64?, networkTransmit: UInt64?,
                             gaps: Int, counterResets: Int, sampleCount: Int = 1) -> [DailyIntervalTotals] {
        guard let start, end > start else {
            return [DailyIntervalTotals(dayStart: utcDayStart(end), cpuSeconds: nil, diskRead: nil,
                                        diskWrite: nil, networkReceive: nil, networkTransmit: nil,
                                        sampleCount: sampleCount, gaps: gaps, counterResets: counterResets)]
        }

        let elapsed = end.timeIntervalSince(start)
        let slices = intervalSlices(from: start, through: end)
        let cpuAmounts = distribute(cpuSeconds, across: slices, over: elapsed)
        let readAmounts = distribute(diskRead, across: slices, over: elapsed)
        let writeAmounts = distribute(diskWrite, across: slices, over: elapsed)
        let receiveAmounts = distribute(networkReceive, across: slices, over: elapsed)
        let transmitAmounts = distribute(networkTransmit, across: slices, over: elapsed)
        return slices.indices.map { index in
            let isEndpointDay = index == slices.count - 1
            return DailyIntervalTotals(
                dayStart: slices[index].dayStart,
                cpuSeconds: cpuAmounts[index], diskRead: readAmounts[index], diskWrite: writeAmounts[index],
                networkReceive: receiveAmounts[index], networkTransmit: transmitAmounts[index],
                sampleCount: isEndpointDay ? sampleCount : 0,
                gaps: isEndpointDay ? gaps : 0,
                counterResets: isEndpointDay ? counterResets : 0)
        }
    }

    private func intervalSlices(from start: Date, through end: Date) -> [DailyIntervalSlice] {
        var slices: [DailyIntervalSlice] = []
        var cursor = start
        while cursor < end {
            let dayStart = utcDayStart(cursor)
            let nextDay = dayStart.addingTimeInterval(86_400)
            let segmentEnd = min(end, nextDay)
            slices.append(DailyIntervalSlice(dayStart: dayStart,
                                             duration: segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        let endpointDay = utcDayStart(end)
        if slices.last?.dayStart != endpointDay {
            slices.append(DailyIntervalSlice(dayStart: endpointDay, duration: 0))
        }
        return slices
    }

    private func distribute(_ total: Double?, across slices: [DailyIntervalSlice],
                            over elapsed: TimeInterval) -> [Double?] {
        guard let total else { return Array(repeating: nil, count: slices.count) }
        var allocated = 0.0
        return slices.indices.map { index -> Double? in
            if index == slices.count - 1 { return max(0, total - allocated) }
            let amount = min(max(0, total - allocated), total * slices[index].duration / elapsed)
            allocated += amount
            return amount
        }
    }

    private func distribute(_ total: UInt64?, across slices: [DailyIntervalSlice],
                            over elapsed: TimeInterval) -> [UInt64?] {
        guard let total else { return Array(repeating: nil, count: slices.count) }
        var allocated: UInt64 = 0
        return slices.indices.map { index -> UInt64? in
            if index == slices.count - 1 { return total - allocated }
            let share = (Double(total) * slices[index].duration / elapsed).rounded(.down)
            let amount = min(total - allocated, UInt64(max(0, share)))
            allocated += amount
            return amount
        }
    }

    private func upsert(_ totals: DailyIntervalTotals, on db: OpaquePointer) throws {
        let sql = """
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
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(totals.dayStart.timeIntervalSince1970))
        bind(totals.cpuSeconds, to: statement, index: 2)
        bind(totals.diskRead, to: statement, index: 3)
        bind(totals.diskWrite, to: statement, index: 4)
        bind(totals.networkReceive, to: statement, index: 5)
        bind(totals.networkTransmit, to: statement, index: 6)
        sqlite3_bind_int64(statement, 7, Int64(totals.sampleCount))
        sqlite3_bind_int64(statement, 8, Int64(totals.gaps))
        sqlite3_bind_int64(statement, 9, Int64(totals.counterResets))
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
    }

    private struct AggregatedApplicationSample {
        let identity: ApplicationHistoryIdentity
        let cpu: MetricReading
        let diskRead: MetricReading
        let diskWrite: MetricReading
        let networkReceive: MetricReading
        let networkTransmit: MetricReading
    }

    private func recordApplicationTotals(snapshot: MonitoringSnapshot, cutoff: Date,
                                         previousSamples: [String: Date], sameSession: Bool,
                                         hasExistingTotals: Bool,
                                         on db: OpaquePointer) throws -> [String: Date] {
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
        var statement: OpaquePointer?
        try prepare(Self.applicationUpsertSQL, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
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
                elapsed = duration > 0 && duration <= 30 ? duration : nil
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
            let networkReceive = try rateTotal(receive, fallbackInterval: applicationInterval, cutoff: cutoff,
                                               stream: .application(key, .receive), on: db)
            let networkTransmit = try rateTotal(transmit, fallbackInterval: applicationInterval, cutoff: cutoff,
                                                stream: .application(key, .transmit), on: db)
            let gap = previous != nil && (!sameSession || elapsed == nil)
                || (!sameSession && hasExistingTotals)
                || sourceReadings.contains { Self.isIncomplete($0.unavailableReason) }
                || readings.contains(where: \.isPartial)
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
                gaps: gap ? 1 : 0, counterResets: reset ? 1 : 0)
            totals += dailyTotals(
                from: networkReceive.interval?.start, through: networkReceive.interval?.end ?? snapshot.timestamp,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: networkReceive.bytes, networkTransmit: nil,
                gaps: 0, counterResets: 0, sampleCount: 0)
            totals += dailyTotals(
                from: networkTransmit.interval?.start, through: networkTransmit.interval?.end ?? snapshot.timestamp,
                cpuSeconds: nil, diskRead: nil, diskWrite: nil,
                networkReceive: nil, networkTransmit: networkTransmit.bytes,
                gaps: 0, counterResets: 0, sampleCount: 0)
            for daily in totals where daily.dayStart >= cutoff {
                sqlite3_bind_int64(statement, 1, Int64(daily.dayStart.timeIntervalSince1970))
                bind(identity.id, to: statement, index: 2)
                bind(identity.name, to: statement, index: 3)
                bind(identity.executablePath, to: statement, index: 4)
                bind(identity.association.rawValue, to: statement, index: 5)
                bind(daily.cpuSeconds, to: statement, index: 6)
                bind(daily.diskRead, to: statement, index: 7)
                bind(daily.diskWrite, to: statement, index: 8)
                bind(daily.networkReceive, to: statement, index: 9)
                bind(daily.networkTransmit, to: statement, index: 10)
                sqlite3_bind_int64(statement, 11, Int64(daily.sampleCount))
                sqlite3_bind_int64(statement, 12, Int64(daily.gaps))
                sqlite3_bind_int64(statement, 13, Int64(daily.counterResets))
                let code = sqlite3_step(statement)
                guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
                sqlite3_reset(statement)
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

    private func utcDayStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
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
}
