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
    public static let schemaVersion: Int32 = 3
    public static let retentionDays = 30

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

    private static let applicationUpsertSQL = """
    INSERT INTO application_daily_totals (
        day_start, application_id, application_name, executable_path, association,
        cpu_seconds, disk_read_bytes, disk_write_bytes, network_receive_bytes,
        network_transmit_bytes, sample_count, gaps, counter_resets
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
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
        sample_count = application_daily_totals.sample_count + 1,
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

            let storedPriorSample = try readPriorSample(on: db)
            let storedPriorApplicationSamples = try readApplicationSamples(on: db)
            let prior = priorSample == storedPriorSample ? priorSample : storedPriorSample
            let priorApplications = priorSample == storedPriorSample
                ? priorApplicationSamples : storedPriorApplicationSamples
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
            let hasSleepGap = prior != nil && (!sameSession || elapsed == nil)
                || hasExistingTotals
                || snapshot.allSystemReadings.contains { $0.unavailableReason == .sleepGap }
            let hasCounterReset = snapshot.allSystemReadings.contains { $0.unavailableReason == .counterReset }
            let validElapsed = elapsed
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
            let networkReceive = snapshot.system.networkReceiveBytesPerSecond.value.flatMap { rate in
                validElapsed.map { Self.byteTotal(rate * $0) }
            }
            let networkTransmit = snapshot.system.networkTransmitBytesPerSecond.value.flatMap { rate in
                validElapsed.map { Self.byteTotal(rate * $0) }
            }

            try upsert(dayStart: today, cpuSeconds: cpuSeconds, diskRead: diskRead, diskWrite: diskWrite,
                       networkReceive: networkReceive, networkTransmit: networkTransmit,
                       gaps: hasSleepGap ? 1 : 0, counterResets: hasCounterReset ? 1 : 0,
                       on: db)
            let currentApplicationSamples = try recordApplicationTotals(
                snapshot: snapshot, dayStart: today, previousSamples: priorApplications,
                sameSession: sameSession, hasExistingTotals: hasExistingTotals, on: db)
            try saveCollectionState(timestamp: now, applicationSamples: currentApplicationSamples,
                                    previousApplicationSamples: priorApplications, on: db)
            try execute("COMMIT", on: db)
            priorSample = PriorSample(timestamp: now, sessionID: sessionID)
            priorApplicationSamples = currentApplicationSamples
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
            try execute("DELETE FROM daily_totals", on: db)
            try execute("DELETE FROM application_daily_totals", on: db)
            try execute("DELETE FROM monitoring_state", on: db)
            try execute("DELETE FROM application_sample_state", on: db)
            try execute("COMMIT", on: db)
            priorSample = nil
            priorApplicationSamples.removeAll()
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
                       'monitoring_state', 'application_sample_state')
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

    private func upsert(dayStart: Date, cpuSeconds: Double?, diskRead: UInt64?, diskWrite: UInt64?,
                        networkReceive: UInt64?, networkTransmit: UInt64?, gaps: Int, counterResets: Int,
                        on db: OpaquePointer) throws {
        let sql = """
        INSERT INTO daily_totals (
            day_start, cpu_seconds, disk_read_bytes, disk_write_bytes,
            network_receive_bytes, network_transmit_bytes, sample_count, gaps, counter_resets
        ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
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
            sample_count = daily_totals.sample_count + 1,
            gaps = daily_totals.gaps + excluded.gaps,
            counter_resets = daily_totals.counter_resets + excluded.counter_resets
        """
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement, on: db)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(dayStart.timeIntervalSince1970))
        bind(cpuSeconds, to: statement, index: 2)
        bind(diskRead, to: statement, index: 3)
        bind(diskWrite, to: statement, index: 4)
        bind(networkReceive, to: statement, index: 5)
        bind(networkTransmit, to: statement, index: 6)
        sqlite3_bind_int64(statement, 7, Int64(gaps))
        sqlite3_bind_int64(statement, 8, Int64(counterResets))
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

    private func recordApplicationTotals(snapshot: MonitoringSnapshot, dayStart: Date,
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
            let interval: TimeInterval?
            if sameSession, let previous {
                let elapsed = snapshot.timestamp.timeIntervalSince(previous)
                interval = elapsed > 0 && elapsed <= 30 ? elapsed : nil
            } else {
                interval = nil
            }
            let gap = previous != nil && (!sameSession || interval == nil)
                || (!sameSession && hasExistingTotals)
                || [cpu, read, write, receive, transmit].contains { $0.unavailableReason == .sleepGap }
            let reset = [cpu, read, write, receive, transmit].contains { $0.unavailableReason == .counterReset }
            let cpuSeconds = cpu.value.flatMap { value in
                interval.map { max(0, value) / 100 * Double(max(1, snapshot.system.capacityCores)) * $0 }
            }
            let readBytes = read.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            let writeBytes = write.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            let receiveBytes = receive.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            let transmitBytes = transmit.value.flatMap { rate in interval.map { Self.byteTotal(rate * $0) } }
            sqlite3_bind_int64(statement, 1, Int64(dayStart.timeIntervalSince1970))
            bind(identity.id, to: statement, index: 2)
            bind(identity.name, to: statement, index: 3)
            bind(identity.executablePath, to: statement, index: 4)
            bind(identity.association.rawValue, to: statement, index: 5)
            bind(cpuSeconds, to: statement, index: 6)
            bind(readBytes, to: statement, index: 7)
            bind(writeBytes, to: statement, index: 8)
            bind(receiveBytes, to: statement, index: 9)
            bind(transmitBytes, to: statement, index: 10)
            sqlite3_bind_int64(statement, 11, Int64(gap ? 1 : 0))
            sqlite3_bind_int64(statement, 12, Int64(reset ? 1 : 0))
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw sqliteError(db, code: code) }
            sqlite3_reset(statement)
            currentApplicationSamples[key] = snapshot.timestamp
        }
        return currentApplicationSamples
    }

    private func combine(_ readings: [MetricReading], unit: MetricUnit, timestamp: Date) -> MetricReading {
        guard !readings.isEmpty else {
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .notCollected)
        }
        if let unavailable = readings.first(where: { !$0.isAvailable }) {
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: unavailable.unavailableReason ?? .collectionFailed,
                                 detail: unavailable.detail)
        }
        return MetricReading(value: readings.compactMap(\.value).reduce(0, +), unit: unit, timestamp: timestamp)
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
    }
}
