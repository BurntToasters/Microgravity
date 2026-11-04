import Foundation

/// Units are explicit so a missing measurement can never be mistaken for zero.
public enum MetricUnit: String, Codable, Hashable, Sendable {
    case percent
    case bytes
    case bytesPerSecond
    case count
    case seconds
    case watts
    case joules
    case wattHours
}

public enum MetricUnavailableReason: String, Codable, Hashable, Sendable {
    case warmingUp
    case permissionDenied
    case unsupported
    case collectionFailed
    case processExited
    case identityChanged
    case counterReset
    case sleepGap
    case notCollected
}

public struct MetricReading: Codable, Equatable, Sendable {
    public let value: Double?
    public let unit: MetricUnit
    public let timestamp: Date
    public let unavailableReason: MetricUnavailableReason?
    public let detail: String?

    public init(value: Double, unit: MetricUnit, timestamp: Date) {
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.unavailableReason = nil
        self.detail = nil
    }

    public init(unavailable unit: MetricUnit, timestamp: Date,
                reason: MetricUnavailableReason, detail: String? = nil) {
        self.value = nil
        self.unit = unit
        self.timestamp = timestamp
        self.unavailableReason = reason
        self.detail = detail
    }

    public var isAvailable: Bool { value != nil }
}

public enum MetricKind: String, Codable, Hashable, Sendable, CaseIterable {
    case totalCPU
    case perCoreCPU
    case physicalMemory
    case memoryPressure
    case swap
    case diskThroughput
    case networkThroughput
    case processes
    case processIO
    case gpu
    case energy
    case processGPUTime
    case processNetwork
    case processNetworkReceive
    case processNetworkTransmit
    case startupItems
    case services
    case userSessions
    case history
}

public struct MetricAvailability: Codable, Equatable, Sendable {
    public let available: Bool
    public let reason: MetricUnavailableReason?
    public let detail: String?

    public init(available: Bool, reason: MetricUnavailableReason? = nil, detail: String? = nil) {
        self.available = available
        self.reason = reason
        self.detail = detail
    }
}

public struct ProcessStartTime: Codable, Hashable, Comparable, Sendable {
    public let secondsSinceEpoch: Int64
    public let microseconds: Int32

    public init(secondsSinceEpoch: Int64, microseconds: Int32) {
        self.secondsSinceEpoch = secondsSinceEpoch
        self.microseconds = microseconds
    }

    public static func < (lhs: ProcessStartTime, rhs: ProcessStartTime) -> Bool {
        if lhs.secondsSinceEpoch != rhs.secondsSinceEpoch {
            return lhs.secondsSinceEpoch < rhs.secondsSinceEpoch
        }
        return lhs.microseconds < rhs.microseconds
    }
}

/// PID alone is not an identity: start time protects against PID reuse.
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTime: ProcessStartTime

    public init(pid: Int32, startTime: ProcessStartTime) {
        self.pid = pid
        self.startTime = startTime
    }
}

public struct ProcessSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: ProcessIdentity
    public let parentIdentity: ProcessIdentity?
    public let parentPID: Int32?
    public let parentExecutablePath: String?
    public let childIdentities: [ProcessIdentity]
    public let name: String
    public let executablePath: String?
    public let ownerUID: UInt32?
    public let isCurrentUser: Bool
    public let cpuPercent: MetricReading
    public let memoryBytes: MetricReading
    public let diskReadBytesPerSecond: MetricReading
    public let diskWriteBytesPerSecond: MetricReading
    public let diskReadTotalBytes: MetricReading
    public let diskWriteTotalBytes: MetricReading
    public let advancedMetrics: [MetricKind: MetricReading]

    public init(id: ProcessIdentity, parentIdentity: ProcessIdentity?, childIdentities: [ProcessIdentity],
                name: String, executablePath: String?, ownerUID: UInt32?, isCurrentUser: Bool,
                cpuPercent: MetricReading, memoryBytes: MetricReading,
                diskReadBytesPerSecond: MetricReading, diskWriteBytesPerSecond: MetricReading,
                diskReadTotalBytes: MetricReading, diskWriteTotalBytes: MetricReading,
                advancedMetrics: [MetricKind: MetricReading] = [:],
                parentPID: Int32? = nil, parentExecutablePath: String? = nil) {
        self.id = id
        self.parentIdentity = parentIdentity
        self.parentPID = parentPID ?? parentIdentity?.pid
        self.parentExecutablePath = parentExecutablePath
        self.childIdentities = childIdentities
        self.name = name
        self.executablePath = executablePath
        self.ownerUID = ownerUID
        self.isCurrentUser = isCurrentUser
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.diskReadTotalBytes = diskReadTotalBytes
        self.diskWriteTotalBytes = diskWriteTotalBytes
        self.advancedMetrics = advancedMetrics
    }
}

public enum ProcessGroupAssociation: String, Codable, Hashable, Sendable {
    case applicationBundle
    case parentProcess
    case standalone
}

public struct ApplicationHistoryIdentity: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let executablePath: String?
    public let association: ProcessGroupAssociation

    public init(id: String, name: String, executablePath: String?, association: ProcessGroupAssociation) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.association = association
    }
}

public struct ProcessGroupSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: ProcessIdentity
    public let title: String
    public let ownerUID: UInt32?
    public let executablePath: String?
    public let association: ProcessGroupAssociation
    public let historyIdentity: ApplicationHistoryIdentity
    public let members: [ProcessIdentity]
    public let cpuPercent: MetricReading
    public let memoryBytes: MetricReading
    public let diskReadBytesPerSecond: MetricReading
    public let diskWriteBytesPerSecond: MetricReading
    public let networkReceiveBytesPerSecond: MetricReading
    public let networkTransmitBytesPerSecond: MetricReading

    public init(id: ProcessIdentity, title: String, ownerUID: UInt32?, executablePath: String?,
                association: ProcessGroupAssociation, historyIdentity: ApplicationHistoryIdentity,
                members: [ProcessIdentity], cpuPercent: MetricReading, memoryBytes: MetricReading,
                diskReadBytesPerSecond: MetricReading, diskWriteBytesPerSecond: MetricReading,
                networkReceiveBytesPerSecond: MetricReading, networkTransmitBytesPerSecond: MetricReading) {
        self.id = id
        self.title = title
        self.ownerUID = ownerUID
        self.executablePath = executablePath
        self.association = association
        self.historyIdentity = historyIdentity
        self.members = members
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkTransmitBytesPerSecond = networkTransmitBytesPerSecond
    }
}

public enum MemoryPressureLevel: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

public struct MemoryPressureSnapshot: Codable, Equatable, Sendable {
    public let level: MemoryPressureLevel?
    public let timestamp: Date
    public let unavailableReason: MetricUnavailableReason?

    public init(level: MemoryPressureLevel, timestamp: Date) {
        self.level = level
        self.timestamp = timestamp
        self.unavailableReason = nil
    }

    public init(unavailable timestamp: Date, reason: MetricUnavailableReason) {
        self.level = nil
        self.timestamp = timestamp
        self.unavailableReason = reason
    }
}

public struct NetworkInterfaceSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isUp: Bool
    public let receiveBytesPerSecond: MetricReading
    public let transmitBytesPerSecond: MetricReading
    public let receiveTotalBytes: MetricReading
    public let transmitTotalBytes: MetricReading

    public init(name: String, isUp: Bool, receiveBytesPerSecond: MetricReading,
                transmitBytesPerSecond: MetricReading, receiveTotalBytes: MetricReading,
                transmitTotalBytes: MetricReading) {
        self.name = name
        self.isUp = isUp
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.transmitBytesPerSecond = transmitBytesPerSecond
        self.receiveTotalBytes = receiveTotalBytes
        self.transmitTotalBytes = transmitTotalBytes
    }
}

public struct SystemMetricsSnapshot: Codable, Equatable, Sendable {
    public let capacityCores: Int
    public let cpuPercent: MetricReading
    public let perCoreCPUPercent: [MetricReading]
    public let memoryUsedBytes: MetricReading
    public let memoryAvailableBytes: MetricReading
    public let memoryTotalBytes: MetricReading
    public let memoryPressure: MemoryPressureSnapshot
    public let swapUsedBytes: MetricReading
    public let swapTotalBytes: MetricReading
    public let diskReadBytesPerSecond: MetricReading
    public let diskWriteBytesPerSecond: MetricReading
    public let networkReceiveBytesPerSecond: MetricReading
    public let networkTransmitBytesPerSecond: MetricReading
    public let networkInterfaces: [NetworkInterfaceSnapshot]

    public init(capacityCores: Int, cpuPercent: MetricReading, perCoreCPUPercent: [MetricReading],
                memoryUsedBytes: MetricReading, memoryAvailableBytes: MetricReading,
                memoryTotalBytes: MetricReading, memoryPressure: MemoryPressureSnapshot,
                swapUsedBytes: MetricReading, swapTotalBytes: MetricReading,
                diskReadBytesPerSecond: MetricReading, diskWriteBytesPerSecond: MetricReading,
                networkReceiveBytesPerSecond: MetricReading,
                networkTransmitBytesPerSecond: MetricReading,
                networkInterfaces: [NetworkInterfaceSnapshot]) {
        self.capacityCores = capacityCores
        self.cpuPercent = cpuPercent
        self.perCoreCPUPercent = perCoreCPUPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkTransmitBytesPerSecond = networkTransmitBytesPerSecond
        self.networkInterfaces = networkInterfaces
    }
}

public enum DiscoveredEntryKind: String, Codable, Hashable, Sendable {
    case loginItem
    case launchAgent
    case launchDaemon
    case service
}

public enum DiscoveredEntryState: String, Codable, Hashable, Sendable {
    case running
    case loaded
    case stopped
    case unknown
}

public struct DiscoveredEntrySnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: DiscoveredEntryKind
    public let name: String
    public let path: String?
    public let ownerUID: UInt32?
    public let state: DiscoveredEntryState
    public let detail: String?

    public init(id: String, kind: DiscoveredEntryKind, name: String, path: String?, ownerUID: UInt32?,
                state: DiscoveredEntryState, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.ownerUID = ownerUID
        self.state = state
        self.detail = detail
    }
}

public struct DiscoveryCoverage: Codable, Equatable, Sendable {
    public let complete: Bool
    public let reasons: [String]

    public init(complete: Bool, reasons: [String] = []) {
        self.complete = complete
        self.reasons = reasons
    }
}

public struct UserSessionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32 { uid }
    public let uid: UInt32
    public let shortName: String
    public let isCurrentUser: Bool
    public let loginSessions: [String]

    public init(uid: UInt32, shortName: String, isCurrentUser: Bool, loginSessions: [String]) {
        self.uid = uid
        self.shortName = shortName
        self.isCurrentUser = isCurrentUser
        self.loginSessions = loginSessions
    }
}

public struct DailyHistorySummary: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { dayStart }
    public let dayStart: Date
    public let cpuSeconds: Double?
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    public let networkReceiveBytes: UInt64?
    public let networkTransmitBytes: UInt64?
    public let sampleCount: Int
    public let gaps: Int
    public let counterResets: Int

    public init(dayStart: Date, cpuSeconds: Double?, diskReadBytes: UInt64?, diskWriteBytes: UInt64?,
                networkReceiveBytes: UInt64?, networkTransmitBytes: UInt64?, sampleCount: Int,
                gaps: Int, counterResets: Int) {
        self.dayStart = dayStart
        self.cpuSeconds = cpuSeconds
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.sampleCount = sampleCount
        self.gaps = gaps
        self.counterResets = counterResets
    }
}

public struct ApplicationDailyHistorySummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(dayStart.timeIntervalSince1970):\(application.id)" }
    public let dayStart: Date
    public let application: ApplicationHistoryIdentity
    public let cpuSeconds: Double?
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    public let networkReceiveBytes: UInt64?
    public let networkTransmitBytes: UInt64?
    public let sampleCount: Int
    public let gaps: Int
    public let counterResets: Int

    public init(dayStart: Date, application: ApplicationHistoryIdentity, cpuSeconds: Double?,
                diskReadBytes: UInt64?, diskWriteBytes: UInt64?, networkReceiveBytes: UInt64?,
                networkTransmitBytes: UInt64?, sampleCount: Int, gaps: Int, counterResets: Int) {
        self.dayStart = dayStart
        self.application = application
        self.cpuSeconds = cpuSeconds
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.sampleCount = sampleCount
        self.gaps = gaps
        self.counterResets = counterResets
    }
}

public struct MonitoringSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let system: SystemMetricsSnapshot
    public let processes: [ProcessSnapshot]
    public let processGroups: [ProcessGroupSnapshot]
    public let startupItems: [DiscoveredEntrySnapshot]
    public let services: [DiscoveredEntrySnapshot]
    public let users: [UserSessionSnapshot]
    public let discoveryCoverage: [String: DiscoveryCoverage]
    public let capabilities: [MetricKind: MetricAvailability]
    public let advancedMetrics: [MetricKind: MetricReading]
    public let history: [DailyHistorySummary]
    public let applicationHistory: [ApplicationDailyHistorySummary]

    public init(timestamp: Date, system: SystemMetricsSnapshot, processes: [ProcessSnapshot],
                processGroups: [ProcessGroupSnapshot], startupItems: [DiscoveredEntrySnapshot],
                services: [DiscoveredEntrySnapshot], users: [UserSessionSnapshot],
                discoveryCoverage: [String: DiscoveryCoverage],
                capabilities: [MetricKind: MetricAvailability],
                advancedMetrics: [MetricKind: MetricReading] = [:],
                history: [DailyHistorySummary] = [],
                applicationHistory: [ApplicationDailyHistorySummary] = []) {
        self.timestamp = timestamp
        self.system = system
        self.processes = processes
        self.processGroups = processGroups
        self.startupItems = startupItems
        self.services = services
        self.users = users
        self.discoveryCoverage = discoveryCoverage
        self.capabilities = capabilities
        self.advancedMetrics = advancedMetrics
        self.history = history
        self.applicationHistory = applicationHistory
    }
}

/// Injection seam for later public integrations such as GPU and energy counters.
/// Values keep their source units (for example joules or watt-hours) and errors.
public struct AdvancedMetricsSnapshot: Codable, Equatable, Sendable {
    public let system: [MetricKind: MetricReading]
    public let perProcess: [ProcessIdentity: [MetricKind: MetricReading]]
    public let capabilities: [MetricKind: MetricAvailability]

    public init(system: [MetricKind: MetricReading] = [:],
                perProcess: [ProcessIdentity: [MetricKind: MetricReading]] = [:],
                capabilities: [MetricKind: MetricAvailability] = [:]) {
        self.system = system
        self.perProcess = perProcess
        self.capabilities = capabilities
    }
}

public protocol AdvancedMetricsCollecting: Sendable {
    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot
}

public struct MonitoringGraphSample: Codable, Equatable, Sendable, Identifiable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let cpuPercent: MetricReading
    public let perCoreCPUPercent: [MetricReading]
    public let memoryUsedBytes: MetricReading
    public let memoryPressure: MemoryPressureSnapshot
    public let swapUsedBytes: MetricReading
    public let swapTotalBytes: MetricReading
    public let diskReadBytesPerSecond: MetricReading
    public let diskWriteBytesPerSecond: MetricReading
    public let networkReceiveBytesPerSecond: MetricReading
    public let networkTransmitBytesPerSecond: MetricReading
    public let advancedMetrics: [MetricKind: MetricReading]

    public init(snapshot: MonitoringSnapshot) {
        timestamp = snapshot.timestamp
        cpuPercent = snapshot.system.cpuPercent
        perCoreCPUPercent = snapshot.system.perCoreCPUPercent
        memoryUsedBytes = snapshot.system.memoryUsedBytes
        memoryPressure = snapshot.system.memoryPressure
        swapUsedBytes = snapshot.system.swapUsedBytes
        swapTotalBytes = snapshot.system.swapTotalBytes
        diskReadBytesPerSecond = snapshot.system.diskReadBytesPerSecond
        diskWriteBytesPerSecond = snapshot.system.diskWriteBytesPerSecond
        networkReceiveBytesPerSecond = snapshot.system.networkReceiveBytesPerSecond
        networkTransmitBytesPerSecond = snapshot.system.networkTransmitBytesPerSecond
        advancedMetrics = snapshot.advancedMetrics
    }
}

public enum MonitoringInterval: Double, Hashable, CaseIterable, Sendable {
    case halfSecond = 0.5
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
}

public protocol MonitoringCollecting: Sendable {
    func collect(at timestamp: Date) async -> MonitoringSnapshot
}

@MainActor
public protocol MonitoringStore: AnyObject {
    var latestSnapshot: MonitoringSnapshot? { get }
    var graphSamples: [MonitoringGraphSample] { get }
    var interval: MonitoringInterval { get }
    var isPaused: Bool { get }
    var isRunning: Bool { get }
    var onSnapshot: (@MainActor @Sendable (MonitoringSnapshot) -> Void)? { get set }

    func start(interval: MonitoringInterval)
    func setInterval(_ interval: MonitoringInterval)
    func pause()
    func resume()
    func stop()
    func refreshNow() async
    func resetHistory() async throws
}

public protocol MonitoringHistoryManaging: Sendable {
    func record(snapshot: MonitoringSnapshot) async throws
    func summaries(lastDays: Int, through date: Date) async throws -> [DailyHistorySummary]
    func reset() async throws
    func applicationSummaries(lastDays: Int, through date: Date) async throws -> [ApplicationDailyHistorySummary]
}

public enum ProcessActionRejection: String, Codable, Hashable, Sendable {
    case invalidIdentity
    case processExited
    case identityChanged
    case currentProcess
    case pidOne
    case protectedProcess
    case differentUser
    case permissionDenied
    case helperUnavailable
    case signalFailed
}

public enum ProcessActionOutcome: Codable, Equatable, Sendable {
    case signalSent
    case rejected(ProcessActionRejection, detail: String?)
}

public struct ProcessActionResult: Codable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let force: Bool
    public let outcome: ProcessActionOutcome

    public init(identity: ProcessIdentity, force: Bool, outcome: ProcessActionOutcome) {
        self.identity = identity
        self.force = force
        self.outcome = outcome
    }
}

public protocol ProcessActioning: Sendable {
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult
}
