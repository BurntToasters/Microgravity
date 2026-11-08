import Darwin
import Dispatch
import Foundation
import IOKit
import IOKit.storage
import MachO
import SystemConfiguration

/// Tracks whether every listed process was either included or legitimately left during the sample.
/// A PID that exited, or was reused by another process, between the listing and the revalidation read is
/// an expected race: it is skipped and counted as departed, and does not make the process list incomplete.
/// Only a revalidation read that fails for any other reason leaves a process unverified.
struct ProcessIdentityCoverage {
    /// Result of re-reading the start time of a listed PID after its task and resource reads.
    enum Revalidation: Equatable {
        case identity(ProcessIdentity)
        case gone
        case unreadable
    }

    enum Omission: Equatable {
        case revalidationUnavailable
    }

    private(set) var omissions: [Omission] = []
    private(set) var departedCount = 0

    var complete: Bool { omissions.isEmpty }

    /// Returns true when the listed process is confirmed and should be included in the snapshot.
    mutating func include(listed: ProcessIdentity, revalidation: Revalidation) -> Bool {
        switch revalidation {
        case let .identity(current) where current == listed:
            return true
        case .identity, .gone:
            departedCount += 1
            return false
        case .unreadable:
            omissions.append(.revalidationUnavailable)
            return false
        }
    }
}

public actor SystemMonitorCollector: MonitoringCollecting {
    private enum CounterKey: Hashable {
        case coreTotal(Int)
        case coreActive(Int)
        case diskRead
        case diskWrite
    }

    private enum ProcessCounterKey: Hashable {
        case cpu(ProcessIdentity)
        case diskRead(ProcessIdentity)
        case diskWrite(ProcessIdentity)
    }

    private struct RawProcess {
        let identity: ProcessIdentity
        let parentPID: Int32
        let name: String
        let path: String?
        let ownerUID: UInt32
        let cpu: MetricReading
        let memory: MetricReading
        let diskReadRate: MetricReading
        let diskWriteRate: MetricReading
        let diskReadTotal: MetricReading
        let diskWriteTotal: MetricReading
    }

    private struct CachedLaunchDiscovery {
        let refreshedAt: Date
        let result: LaunchDiscoveryResult
    }

    private struct CachedUserDiscovery {
        let refreshedAt: Date
        let result: UserDiscoveryResult
    }

    private struct CachedBundleMetadata {
        let bundleID: String?
        let title: String
    }

    /// Name and executable path are read once per ProcessIdentity and evicted with the identity.
    private struct CachedProcessText {
        let name: String
        let path: String?
    }

    /// The process table is read up to this many entries per sample; beyond it the snapshot is incomplete.
    static let maximumPIDCount = 16_384
    static let processEnumerationCapDetail = "Process enumeration stopped at the \(maximumPIDCount)-process cap of KERN_PROC_ALL; processes beyond the cap were not read."
    static let processIdentityOmissionDetail = "Process enumeration omitted processes whose identity could not be revalidated."
    private static let processTableAttempts = 4
    private static let applicationBundlePathCacheLimit = 4_096

    /// Mach absolute-time to nanosecond factor (125/3 on Apple Silicon, 1/1 on Intel). Read once.
    private static let machTimebase: (numer: UInt64, denom: UInt64)? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return nil }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Reads kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical. Nil when the sysctl fails.
    static func kernelMemoryPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return level
    }

    private static let bundleMetadataCacheLimit = 256

    private let advancedCollector: (any AdvancedMetricsCollecting)?
    private let memoryPressureLevelReader: @Sendable () -> Int32?
    private var systemCounters = CounterDeltaTracker<CounterKey>()
    private var processCounters = CounterDeltaTracker<ProcessCounterKey>()
    private var processTextCache: [ProcessIdentity: CachedProcessText] = [:]
    /// Keyed by standardized executable path; nil records a path with no enclosing .app bundle.
    private var applicationBundlePathCache: [String: String?] = [:]
    private var networkCounterTracker = NetworkInterfaceCounterTracker()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pressureLevel: MemoryPressureLevel?
    private var pressureTimestamp: Date?
    private var cachedLaunchDiscovery: CachedLaunchDiscovery?
    private var cachedUserDiscovery: CachedUserDiscovery?
    private var bundleMetadataCache: [String: CachedBundleMetadata] = [:]
    private var bundleMetadataOrder: [String] = []

    public init(advancedCollector: (any AdvancedMetricsCollecting)? = nil,
                memoryPressureLevelReader: (@Sendable () -> Int32?)? = nil) {
        self.advancedCollector = advancedCollector
        self.memoryPressureLevelReader = memoryPressureLevelReader ?? { Self.kernelMemoryPressureLevel() }
    }

    public func collect(at timestamp: Date) async -> MonitoringSnapshot {
        startMemoryPressureSourceIfNeeded()

        let cpu = collectCPU(at: timestamp)
        let memory = collectMemory(at: timestamp)
        let disk = collectDisk(at: timestamp)
        let network = collectNetwork(at: timestamp)
        let processResult = collectProcesses(at: timestamp, capacityCores: cpu.capacityCores)
        let rawProcesses = processResult.processes
        let processIncompleteDetail = processResult.incompleteDetail
        let baseProcesses = linkProcesses(rawProcesses)
        let advanced = await advancedCollector?.collectAdvancedMetrics(at: timestamp) ?? AdvancedMetricsSnapshot()
        let processes = baseProcesses.map { process in
            var values = advanced.perProcess[process.id] ?? [:]
            if values[.processGPUTime] == nil {
                values[.processGPUTime] = Self.missingAdvancedReading(.processGPUTime, unit: .seconds,
                                                                      timestamp: timestamp, snapshot: advanced,
                                                                      hasProvider: advancedCollector != nil)
            }
            if values[.processNetwork] == nil {
                values[.processNetwork] = Self.missingAdvancedReading(.processNetwork, unit: .bytesPerSecond,
                                                                      timestamp: timestamp, snapshot: advanced,
                                                                      hasProvider: advancedCollector != nil)
            }
            if values[.processNetworkReceive] == nil {
                values[.processNetworkReceive] = Self.missingAdvancedReading(.processNetworkReceive,
                    unit: .bytesPerSecond, timestamp: timestamp, snapshot: advanced,
                    hasProvider: advancedCollector != nil)
            }
            if values[.processNetworkTransmit] == nil {
                values[.processNetworkTransmit] = Self.missingAdvancedReading(.processNetworkTransmit,
                    unit: .bytesPerSecond, timestamp: timestamp, snapshot: advanced,
                    hasProvider: advancedCollector != nil)
            }
            return ProcessSnapshot(id: process.id, parentIdentity: process.parentIdentity,
                                   childIdentities: process.childIdentities, name: process.name,
                                   executablePath: process.executablePath, ownerUID: process.ownerUID,
                                   isCurrentUser: process.isCurrentUser, cpuPercent: process.cpuPercent,
                                   memoryBytes: process.memoryBytes,
                                   diskReadBytesPerSecond: process.diskReadBytesPerSecond,
                                   diskWriteBytesPerSecond: process.diskWriteBytesPerSecond,
                                   diskReadTotalBytes: process.diskReadTotalBytes,
                                   diskWriteTotalBytes: process.diskWriteTotalBytes,
                                   advancedMetrics: values, parentPID: process.parentPID,
                                   parentExecutablePath: process.parentExecutablePath)
        }
        let groups = buildProcessGroups(processes, timestamp: timestamp)
        let inventory = discoverLaunchEntries(processes: processes, at: timestamp)
        let sessions = discoverUsers(at: timestamp)

        var advancedReadings = advanced.system
        if advancedReadings[.gpu] == nil {
            advancedReadings[.gpu] = MetricReading(unavailable: .percent, timestamp: timestamp,
                                                   reason: .unsupported)
        }
        if advancedReadings[.energy] == nil {
            advancedReadings[.energy] = MetricReading(unavailable: .watts, timestamp: timestamp,
                                                     reason: .unsupported)
        }

        let system = SystemMetricsSnapshot(
            capacityCores: cpu.capacityCores,
            cpuPercent: cpu.total,
            perCoreCPUPercent: cpu.perCore,
            memoryUsedBytes: memory.used,
            memoryAvailableBytes: memory.available,
            memoryTotalBytes: memory.total,
            memoryPressure: memory.pressure,
            swapUsedBytes: memory.swapUsed,
            swapTotalBytes: memory.swapTotal,
            diskReadBytesPerSecond: disk.readRate,
            diskWriteBytesPerSecond: disk.writeRate,
            networkReceiveBytesPerSecond: network.receiveRate,
            networkTransmitBytesPerSecond: network.transmitRate,
            networkInterfaces: network.interfaces)

        let capabilities: [MetricKind: MetricAvailability] = [
            .totalCPU: Self.availability(for: cpu.total),
            .perCoreCPU: Self.availability(for: cpu.perCore),
            .physicalMemory: Self.availability(for: memory.used),
            .memoryPressure: MetricAvailability(available: memory.pressure.level != nil,
                                                reason: memory.pressure.unavailableReason),
            .swap: Self.availability(for: memory.swapUsed),
            .diskThroughput: Self.availability(for: [disk.readRate, disk.writeRate]),
            .networkThroughput: Self.availability(for: [network.receiveRate, network.transmitRate]),
            .processes: MetricAvailability(available: processResult.complete,
                                          reason: processResult.complete ? nil : .collectionFailed,
                                          detail: processIncompleteDetail),
            .startupItems: Self.availability(for: inventory.startupCoverage),
            .services: Self.availability(for: inventory.serviceCoverage),
            .userSessions: Self.availability(for: sessions.coverage),
            .history: MetricAvailability(available: false, reason: .notCollected),
            .gpu: advanced.capabilities[.gpu] ?? Self.availability(for: advancedReadings[.gpu]),
            .energy: advanced.capabilities[.energy] ?? Self.availability(for: advancedReadings[.energy]),
            .processGPUTime: advanced.capabilities[.processGPUTime]
                ?? Self.availability(for: processes.first?.advancedMetrics[.processGPUTime]),
            .processNetwork: advanced.capabilities[.processNetwork]
                ?? Self.availability(for: processes.first?.advancedMetrics[.processNetwork]),
            .processNetworkReceive: advanced.capabilities[.processNetworkReceive]
                ?? Self.availability(for: processes.first?.advancedMetrics[.processNetworkReceive]),
            .processNetworkTransmit: advanced.capabilities[.processNetworkTransmit]
                ?? Self.availability(for: processes.first?.advancedMetrics[.processNetworkTransmit]),
        ]

        var allCapabilities = capabilities
        allCapabilities.merge(advanced.capabilities) { _, incoming in incoming }
        let coverage: [String: DiscoveryCoverage] = [
            "processes": DiscoveryCoverage(complete: processResult.complete,
                                           reasons: processIncompleteDetail.map { [$0] } ?? []),
            "startupItems": inventory.startupCoverage,
            "services": inventory.serviceCoverage,
            "users": sessions.coverage,
        ]

        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: processes,
                                  processGroups: groups, startupItems: inventory.startupItems,
                                  services: inventory.services, users: sessions.users,
                                  discoveryCoverage: coverage, capabilities: allCapabilities,
                                  advancedMetrics: advancedReadings)
    }

    private func collectCPU(at timestamp: Date) -> (capacityCores: Int, total: MetricReading, perCore: [MetricReading]) {
        var coreCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, coreCount > 0 else {
            let unavailable = MetricReading(unavailable: .percent, timestamp: timestamp,
                                            reason: .collectionFailed, detail: "host_processor_info failed: \(result)")
            return (max(1, ProcessInfo.processInfo.activeProcessorCount), unavailable, [unavailable])
        }
        defer {
            let address = vm_address_t(bitPattern: info)
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, address, size)
        }

        var perCore: [MetricReading] = []
        var totalActive: UInt64 = 0
        var totalTicks: UInt64 = 0
        var failure: MetricReading?
        for core in 0..<Int(coreCount) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let active = user + system + nice
            let total = active + idle
            let totalResult = systemCounters.update(total, for: .coreTotal(core), at: timestamp)
            let activeResult = systemCounters.update(active, for: .coreActive(core), at: timestamp)
            if case let .delta(totalDelta, _) = totalResult,
               case let .delta(activeDelta, _) = activeResult,
               totalDelta > 0, activeDelta <= totalDelta {
                perCore.append(MetricReading(value: Double(activeDelta) / Double(totalDelta) * 100,
                                             unit: .percent, timestamp: timestamp))
                totalActive += activeDelta
                totalTicks += totalDelta
            } else {
                let reason = totalResult.unavailableReason ?? activeResult.unavailableReason ?? .collectionFailed
                let preferred = MetricReading(unavailable: .percent, timestamp: timestamp, reason: reason)
                perCore.append(preferred)
                if failure == nil { failure = preferred }
            }
        }

        let capacity = Int(coreCount)
        let systemTotal: MetricReading
        if perCore.count == capacity, perCore.allSatisfy(\.isAvailable), totalTicks > 0 {
            systemTotal = MetricReading(value: Double(totalActive) / Double(totalTicks) * 100,
                                        unit: .percent, timestamp: timestamp)
        } else {
            systemTotal = failure ?? MetricReading(unavailable: .percent, timestamp: timestamp,
                                                   reason: .warmingUp)
        }
        return (capacity, systemTotal, perCore)
    }

    private func collectMemory(at timestamp: Date) -> (used: MetricReading, available: MetricReading,
                                                       total: MetricReading, pressure: MemoryPressureSnapshot,
                                                       swapUsed: MetricReading, swapTotal: MetricReading) {
        var physicalBytes: UInt64 = 0
        var physicalLength = MemoryLayout<UInt64>.size
        let physicalResult = sysctlbyname("hw.memsize", &physicalBytes, &physicalLength, nil, 0)
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        var stats = vm_statistics64_data_t()
        var statsCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let statsResult = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(statsCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &statsCount)
            }
        }
        let memoryOK = physicalResult == 0 && pageResult == KERN_SUCCESS && statsResult == KERN_SUCCESS
        let memoryUsed: MetricReading
        let memoryAvailable: MetricReading
        let memoryTotal: MetricReading
        if memoryOK, physicalBytes > 0 {
            let breakdown = Self.memoryBreakdown(
                physicalBytes: physicalBytes,
                pageBytes: UInt64(pageSize),
                internalPages: UInt64(stats.internal_page_count),
                purgeablePages: UInt64(stats.purgeable_count),
                wirePages: UInt64(stats.wire_count),
                compressorPages: UInt64(stats.compressor_page_count))
            memoryAvailable = MetricReading(value: Double(breakdown.availableBytes), unit: .bytes, timestamp: timestamp)
            memoryTotal = MetricReading(value: Double(physicalBytes), unit: .bytes, timestamp: timestamp)
            memoryUsed = MetricReading(value: Double(breakdown.usedBytes), unit: .bytes, timestamp: timestamp)
        } else {
            let reason: MetricUnavailableReason = physicalResult == 0 ? .collectionFailed : .permissionDenied
            memoryUsed = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
            memoryAvailable = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
            memoryTotal = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let swapUsed: MetricReading
        let swapTotal: MetricReading
        if swapResult == 0 {
            swapUsed = MetricReading(value: Double(swap.xsu_used), unit: .bytes, timestamp: timestamp)
            swapTotal = MetricReading(value: Double(swap.xsu_total), unit: .bytes, timestamp: timestamp)
        } else {
            swapUsed = MetricReading(unavailable: .bytes, timestamp: timestamp,
                                     reason: .collectionFailed, detail: "vm.swapusage returned errno \(errno)")
            swapTotal = MetricReading(unavailable: .bytes, timestamp: timestamp,
                                      reason: .collectionFailed, detail: "vm.swapusage returned errno \(errno)")
        }

        return (memoryUsed, memoryAvailable, memoryTotal, resolveMemoryPressure(at: timestamp),
                swapUsed, swapTotal)
    }

    /// The OS-reported level is the baseline on every sample. Dispatch events refine it between samples:
    /// an event that already reported the same level keeps its (fresher) timestamp.
    /// Unavailable only when the sysctl fails and no event has arrived yet.
    private func resolveMemoryPressure(at timestamp: Date) -> MemoryPressureSnapshot {
        if let raw = memoryPressureLevelReader(), let level = Self.memoryPressureLevel(fromSysctl: raw) {
            if pressureLevel != level {
                pressureLevel = level
                pressureTimestamp = timestamp
            } else if pressureTimestamp == nil {
                pressureTimestamp = timestamp
            }
        }
        if let pressureLevel, let pressureTimestamp {
            return MemoryPressureSnapshot(level: pressureLevel, timestamp: pressureTimestamp)
        }
        return MemoryPressureSnapshot(unavailable: timestamp, reason: .collectionFailed)
    }

    static func memoryPressureLevel(fromSysctl raw: Int32) -> MemoryPressureLevel? {
        switch raw {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    private func collectDisk(at timestamp: Date) -> (readRate: MetricReading, writeRate: MetricReading) {
        guard let totals = diskByteTotals() else {
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed, detail: "IOKit block-storage counters unavailable")
            systemCounters.remove(.diskRead)
            systemCounters.remove(.diskWrite)
            return (unavailable, unavailable)
        }
        let read = systemCounters.update(totals.read, for: .diskRead, at: timestamp)
            .reading(unit: .bytesPerSecond, timestamp: timestamp) { value, elapsed in Double(value) / elapsed }
        let write = systemCounters.update(totals.write, for: .diskWrite, at: timestamp)
            .reading(unit: .bytesPerSecond, timestamp: timestamp) { value, elapsed in Double(value) / elapsed }
        return (read, write)
    }

    private func diskByteTotals() -> (read: UInt64, write: UInt64)? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var found = false
        var visited = 0
        var service = IOIteratorNext(iterator)
        while service != 0 && visited < 128 {
            let currentService = service
            defer { IOObjectRelease(currentService) }
            visited += 1
            if let property = IORegistryEntryCreateCFProperty(currentService, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let readCount = property["Bytes (Read)"] as? NSNumber,
               let writeCount = property["Bytes (Write)"] as? NSNumber {
                read &+= readCount.uint64Value
                write &+= writeCount.uint64Value
                found = true
            }
            service = IOIteratorNext(iterator)
        }
        if service != 0 { IOObjectRelease(service) }
        return found ? (read, write) : nil
    }

    private func collectNetwork(at timestamp: Date) -> (receiveRate: MetricReading, transmitRate: MetricReading,
                                                        interfaces: [NetworkInterfaceSnapshot]) {
        do {
            let result = networkCounterTracker.collect(try NetworkInterfaceReader.read(), at: timestamp)
            return (result.receiveRate, result.transmitRate, result.interfaces)
        } catch {
            networkCounterTracker.clear()
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed, detail: String(describing: error))
            return (unavailable, unavailable, [])
        }
    }

    private func collectProcesses(at timestamp: Date, capacityCores: Int)
        -> (processes: [RawProcess], complete: Bool, incompleteDetail: String?) {
        let table: ProcessTable
        switch Self.readProcessTable() {
        case let .success(value):
            table = value
        case let .failure(failure):
            return ([], false, failure.detail)
        }

        var records: [RawProcess] = []
        records.reserveCapacity(table.entries.count)
        var identities = Set<ProcessIdentity>()
        var identityCoverage = ProcessIdentityCoverage()

        for entry in table.entries {
            let rawPID = entry.kp_proc.p_pid
            // Zombies have exited and hold no task or resources; their reads fail, which would surface
            // as collection failures and history gaps for a process that is already gone.
            guard rawPID > 0, Int32(entry.kp_proc.p_stat) != SZOMB else { continue }
            let identity = Self.identity(of: entry)
            let parentPID = entry.kp_eproc.e_ppid
            let ownerUID = UInt32(entry.kp_eproc.e_ucred.cr_uid)
            let kernelName = Self.fixedCString(entry.kp_proc.p_comm)

            var task = proc_taskinfo()
            let taskSize = proc_pidinfo(rawPID, PROC_PIDTASKINFO, 0, &task,
                                        Int32(MemoryLayout<proc_taskinfo>.size))
            let taskAvailable = taskSize == MemoryLayout<proc_taskinfo>.size
            let taskErrno = errno
            let cpuReading: MetricReading
            if taskAvailable, let timebase = Self.machTimebase {
                // proc_taskinfo CPU times are Mach absolute-time ticks, not nanoseconds.
                let ticks = task.pti_total_user &+ task.pti_total_system
                let cpuNanos = Self.nanoseconds(fromMachTicks: ticks, timebase: timebase)
                let delta = processCounters.update(cpuNanos, for: .cpu(identity), at: timestamp)
                cpuReading = delta.reading(unit: .percent, timestamp: timestamp) { value, elapsed in
                    guard capacityCores > 0 else { return 0 }
                    return Double(value) / elapsed / 1_000_000_000 / Double(capacityCores) * 100
                }
            } else {
                processCounters.remove(.cpu(identity))
                let reason: MetricUnavailableReason = taskAvailable ? .collectionFailed
                    : (taskErrno == EPERM ? .permissionDenied : .collectionFailed)
                cpuReading = MetricReading(unavailable: .percent, timestamp: timestamp, reason: reason)
            }

            var usage = rusage_info_v4()
            let usageStatus = withUnsafeMutableBytes(of: &usage) { bytes in
                proc_pid_rusage(rawPID, RUSAGE_INFO_V4,
                                bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            let usageErrno = errno
            let usageAvailable = usageStatus == 0
            let memoryReading: MetricReading
            let diskReadTotal: MetricReading
            let diskWriteTotal: MetricReading
            let diskReadRate: MetricReading
            let diskWriteRate: MetricReading
            if usageAvailable {
                memoryReading = MetricReading(value: Double(usage.ri_phys_footprint), unit: .bytes, timestamp: timestamp)
                diskReadTotal = MetricReading(value: Double(usage.ri_diskio_bytesread), unit: .bytes, timestamp: timestamp)
                diskWriteTotal = MetricReading(value: Double(usage.ri_diskio_byteswritten), unit: .bytes, timestamp: timestamp)
                diskReadRate = processCounters.update(usage.ri_diskio_bytesread, for: .diskRead(identity), at: timestamp)
                    .reading(unit: .bytesPerSecond, timestamp: timestamp) { Double($0) / $1 }
                diskWriteRate = processCounters.update(usage.ri_diskio_byteswritten, for: .diskWrite(identity), at: timestamp)
                    .reading(unit: .bytesPerSecond, timestamp: timestamp) { Double($0) / $1 }
            } else {
                processCounters.remove(.diskRead(identity))
                processCounters.remove(.diskWrite(identity))
                let reason: MetricUnavailableReason = usageErrno == EPERM ? .permissionDenied : .collectionFailed
                memoryReading = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
                diskReadTotal = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
                diskWriteTotal = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: reason)
                diskReadRate = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: reason)
                diskWriteRate = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: reason)
            }

            // Revalidation detects PID reuse during this sample. If the PID is gone or now belongs to another
            // start time, the task and resource reads above may describe a different process, so they are dropped.
            guard identityCoverage.include(listed: identity, revalidation: Self.revalidateIdentity(of: rawPID)) else {
                processCounters.remove(.cpu(identity))
                processCounters.remove(.diskRead(identity))
                processCounters.remove(.diskWrite(identity))
                continue
            }
            let text = processText(for: identity, pid: rawPID, kernelName: kernelName)
            records.append(RawProcess(identity: identity, parentPID: parentPID,
                                      name: text.name,
                                      path: text.path, ownerUID: ownerUID,
                                      cpu: cpuReading, memory: memoryReading,
                                      diskReadRate: diskReadRate, diskWriteRate: diskWriteRate,
                                      diskReadTotal: diskReadTotal, diskWriteTotal: diskWriteTotal))
            identities.insert(identity)
        }
        processCounters.retain(Set(identities.flatMap {
            [ProcessCounterKey.cpu($0), .diskRead($0), .diskWrite($0)]
        }))
        processTextCache = processTextCache.filter { identities.contains($0.key) }

        let incompleteDetail: String?
        if table.truncatedAtCap {
            incompleteDetail = Self.processEnumerationCapDetail
        } else if !identityCoverage.complete {
            incompleteDetail = Self.processIdentityOmissionDetail
        } else {
            incompleteDetail = nil
        }
        return (records, incompleteDetail == nil, incompleteDetail)
    }

    private enum ProcessEnumerationFailure: Error {
        case sysctl(Int32)
        case unstable

        var detail: String {
            switch self {
            case let .sysctl(code):
                return "Process enumeration failed: sysctl KERN_PROC_ALL returned errno \(code)."
            case .unstable:
                return "Process enumeration could not read a stable process table."
            }
        }
    }

    private struct ProcessTable {
        let entries: [kinfo_proc]
        /// True when the table reached maximumPIDCount, so processes beyond the cap were not read.
        let truncatedAtCap: Bool
    }

    /// Lists every process with one KERN_PROC_ALL sysctl. Unlike proc_pidinfo, this needs no per-process
    /// privilege, so processes owned by other users are included.
    private static func readProcessTable() -> Result<ProcessTable, ProcessEnumerationFailure> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let entrySize = MemoryLayout<kinfo_proc>.stride
        for attempt in 1...processTableAttempts {
            var requiredBytes = 0
            let sizeStatus = mib.withUnsafeMutableBufferPointer { name in
                sysctl(name.baseAddress, u_int(name.count), nil, &requiredBytes, nil, 0)
            }
            guard sizeStatus == 0 else { return .failure(.sysctl(errno)) }

            // Headroom absorbs processes started between the sizing call and the read.
            let estimated = requiredBytes / entrySize
            let capacity = min(maximumPIDCount, estimated + estimated / 8 + 64)
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var bytes = capacity * entrySize
            let readStatus = table.withUnsafeMutableBytes { buffer in
                mib.withUnsafeMutableBufferPointer { name in
                    sysctl(name.baseAddress, u_int(name.count), buffer.baseAddress, &bytes, nil, 0)
                }
            }
            if readStatus != 0 {
                let code = errno
                if code == ENOMEM, attempt < processTableAttempts { continue }
                return .failure(.sysctl(code))
            }
            let filled = min(bytes / entrySize, capacity)
            if filled < capacity {
                return .success(ProcessTable(entries: Array(table.prefix(filled)), truncatedAtCap: false))
            }
            if capacity == maximumPIDCount {
                return .success(ProcessTable(entries: table, truncatedAtCap: true))
            }
            // The table may have grown past the buffer, so the next attempt sizes it again.
        }
        return .failure(.unstable)
    }

    private static func identity(of entry: kinfo_proc) -> ProcessIdentity {
        ProcessIdentity(pid: entry.kp_proc.p_pid,
                        startTime: ProcessStartTime(secondsSinceEpoch: Int64(entry.kp_proc.p_un.__p_starttime.tv_sec),
                                                    microseconds: Int32(entry.kp_proc.p_un.__p_starttime.tv_usec)))
    }

    /// Identities for every live process in the same KERN_PROC_ALL table that collectProcesses reads, so
    /// processes owned by other users (including root's) are covered. Zombies and pid <= 0 are skipped.
    /// A failed or unstable read returns no identities with a detail; a table cut at the cap keeps its identities.
    nonisolated static func processIdentityLookup() -> ProcessIdentityLookup {
        switch readProcessTable() {
        case let .failure(failure):
            return ProcessIdentityLookup(identities: [:], failureDetail: failure.detail)
        case let .success(table):
            var identities: [Int32: ProcessIdentity] = [:]
            identities.reserveCapacity(table.entries.count)
            for entry in table.entries {
                let pid = entry.kp_proc.p_pid
                guard pid > 0, Int32(entry.kp_proc.p_stat) != SZOMB else { continue }
                identities[pid] = identity(of: entry)
            }
            return ProcessIdentityLookup(identities: identities,
                                         failureDetail: table.truncatedAtCap ? processEnumerationCapDetail : nil)
        }
    }

    /// Re-reads one PID through KERN_PROC_PID, which also succeeds for other users' processes.
    /// A missing PID returns success with no record, so that case is reported as gone, not as a failure.
    private static func revalidateIdentity(of pid: pid_t) -> ProcessIdentityCoverage.Revalidation {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, u_int(name.count), &entry, &size, nil, 0)
        }
        if status != 0 {
            return errno == ESRCH || errno == ENOENT ? .gone : .unreadable
        }
        guard size == MemoryLayout<kinfo_proc>.size, entry.kp_proc.p_pid == pid else { return .gone }
        return .identity(identity(of: entry))
    }

    /// Name and path are read at most once per ProcessIdentity; evicted with the identity in collectProcesses.
    private func processText(for identity: ProcessIdentity, pid: pid_t, kernelName: String) -> CachedProcessText {
        if let cached = processTextCache[identity] { return cached }
        let path = processPath(pid)
        let text = CachedProcessText(name: Self.processName(executablePath: path, kernelName: kernelName),
                                     path: path)
        processTextCache[identity] = text
        return text
    }

    /// The executable's last path component is the full name. The kernel's p_comm is truncated to MAXCOMLEN,
    /// so it is only the fallback when no executable path is available.
    static func processName(executablePath: String?, kernelName: String) -> String {
        if let executablePath {
            let lastComponent = (executablePath as NSString).lastPathComponent
            if !lastComponent.isEmpty { return lastComponent }
        }
        return kernelName
    }

    /// Converts Mach absolute-time ticks to nanoseconds as ticks * numer / denom, split so the
    /// intermediate product cannot overflow for any realistic counter. Saturates instead of wrapping.
    static func nanoseconds(fromMachTicks ticks: UInt64, timebase: (numer: UInt64, denom: UInt64)) -> UInt64 {
        let whole = ticks / timebase.denom
        let remainder = ticks % timebase.denom
        let (wholeNanos, wholeOverflow) = whole.multipliedReportingOverflow(by: timebase.numer)
        let (remainderNanos, remainderOverflow) = remainder.multipliedReportingOverflow(by: timebase.numer)
        guard !wholeOverflow, !remainderOverflow else { return UInt64.max }
        let (total, totalOverflow) = wholeNanos.addingReportingOverflow(remainderNanos / timebase.denom)
        return totalOverflow ? UInt64.max : total
    }

    private func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private func linkProcesses(_ raw: [RawProcess]) -> [ProcessSnapshot] {
        // PIDs are unique within one listing, but a trap here would abort the whole app, so keep the first on any clash.
        let byPID = Dictionary(raw.map { ($0.identity.pid, $0.identity) }, uniquingKeysWith: { first, _ in first })
        let rawByPID = Dictionary(raw.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: raw, by: \.parentPID)
        let currentUID = UInt32(getuid())
        return raw.map { process in
            let parent = byPID[process.parentPID]
            let parentPath = rawByPID[process.parentPID]?.path
            let childIDs = (children[process.identity.pid] ?? []).map(\.identity).sorted { $0.pid < $1.pid }
            return ProcessSnapshot(id: process.identity, parentIdentity: parent,
                                   childIdentities: childIDs, name: process.name,
                                   executablePath: process.path, ownerUID: process.ownerUID,
                                   isCurrentUser: process.ownerUID == currentUID,
                                   cpuPercent: process.cpu, memoryBytes: process.memory,
                                   diskReadBytesPerSecond: process.diskReadRate,
                                   diskWriteBytesPerSecond: process.diskWriteRate,
                                   diskReadTotalBytes: process.diskReadTotal,
                                   diskWriteTotalBytes: process.diskWriteTotal,
                                   parentPID: process.parentPID > 0 ? process.parentPID : nil,
                                   parentExecutablePath: parentPath)
        }
    }

    private func buildProcessGroups(_ processes: [ProcessSnapshot], timestamp: Date) -> [ProcessGroupSnapshot] {
        let byID = Dictionary(processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var appGroups: [ProcessIdentity: (root: ProcessSnapshot, identity: ApplicationHistoryIdentity,
                                         members: [ProcessSnapshot])] = [:]
        var assigned = Set<ProcessIdentity>()

        for process in processes.sorted(by: { $0.id.pid < $1.id.pid }) {
            guard let (root, bundlePath, bundleID, title) = appRoot(for: process, byID: byID) else { continue }
            let appID: String
            if let bundleID, !bundleID.isEmpty {
                appID = "bundle:\(bundleID)"
            } else {
                appID = "bundle:\(bundlePath)"
            }
            let history = ApplicationHistoryIdentity(id: appID, name: title,
                                                     executablePath: bundlePath,
                                                     association: .applicationBundle)
            if appGroups[root.id] == nil { appGroups[root.id] = (root, history, []) }
            appGroups[root.id]?.members.append(process)
            assigned.insert(process.id)
        }

        var output: [ProcessGroupSnapshot] = []
        for group in appGroups.values {
            let members = uniqueProcesses(group.members)
            output.append(makeGroup(root: group.root, title: group.identity.name,
                                    association: .applicationBundle, history: group.identity,
                                    members: members, timestamp: timestamp))
        }

        for process in processes.sorted(by: { $0.id.pid < $1.id.pid }) where !assigned.contains(process.id) {
            if let parentID = process.parentIdentity, let parent = byID[parentID],
               parent.ownerUID == process.ownerUID, isLaunchd(parent) {
                let descendants = sameOwnerDescendants(of: process, byID: byID, assigned: assigned)
                let members = uniqueProcesses([process] + descendants)
                assigned.formUnion(members.map(\.id))
                let history = historyIdentity(for: process, association: .parentProcess)
                output.append(makeGroup(root: process, title: process.name,
                                        association: .parentProcess, history: history,
                                        members: members, timestamp: timestamp))
            } else {
                assigned.insert(process.id)
                let history = historyIdentity(for: process, association: .standalone)
                output.append(makeGroup(root: process, title: process.name,
                                        association: .standalone, history: history,
                                        members: [process], timestamp: timestamp))
            }
        }
        return output.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func sameOwnerDescendants(of root: ProcessSnapshot, byID: [ProcessIdentity: ProcessSnapshot],
                                      assigned: Set<ProcessIdentity>) -> [ProcessSnapshot] {
        var descendants: [ProcessSnapshot] = []
        var queue = root.childIdentities
        var visited = Set<ProcessIdentity>()
        while let next = queue.popLast() {
            guard visited.insert(next).inserted, !assigned.contains(next), let child = byID[next],
                  child.ownerUID == root.ownerUID else { continue }
            if appRoot(for: child, byID: byID) != nil { continue }
            descendants.append(child)
            queue.append(contentsOf: child.childIdentities)
        }
        return descendants
    }

    private func uniqueProcesses(_ processes: [ProcessSnapshot]) -> [ProcessSnapshot] {
        var seen = Set<ProcessIdentity>()
        return processes.filter { seen.insert($0.id).inserted }
    }

    private func makeGroup(root: ProcessSnapshot, title: String, association: ProcessGroupAssociation,
                           history: ApplicationHistoryIdentity, members: [ProcessSnapshot],
                           timestamp: Date) -> ProcessGroupSnapshot {
        ProcessGroupSnapshot(
            id: root.id, title: title, ownerUID: root.ownerUID, executablePath: history.executablePath,
            association: association, historyIdentity: history,
            members: members.map(\.id),
            cpuPercent: Self.combineRates(members.map(\.cpuPercent), unit: .percent, timestamp: timestamp),
            memoryBytes: Self.combineRates(members.map(\.memoryBytes), unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: Self.combineRates(members.map(\.diskReadBytesPerSecond),
                                                      unit: .bytesPerSecond, timestamp: timestamp),
            diskWriteBytesPerSecond: Self.combineRates(members.map(\.diskWriteBytesPerSecond),
                                                       unit: .bytesPerSecond, timestamp: timestamp),
            networkReceiveBytesPerSecond: Self.combineRates(members.map { $0.advancedMetrics[.processNetworkReceive] ??
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .unsupported) },
                unit: .bytesPerSecond, timestamp: timestamp),
            networkTransmitBytesPerSecond: Self.combineRates(members.map { $0.advancedMetrics[.processNetworkTransmit] ??
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .unsupported) },
                unit: .bytesPerSecond, timestamp: timestamp))
    }

    private func appRoot(for process: ProcessSnapshot, byID: [ProcessIdentity: ProcessSnapshot])
        -> (ProcessSnapshot, String, String?, String)? {
        var current: ProcessSnapshot? = process
        var visited = Set<ProcessIdentity>()
        while let candidate = current, visited.insert(candidate.id).inserted {
            if let path = candidate.executablePath, let bundlePath = applicationBundlePath(path) {
                var root = candidate
                while let parentID = root.parentIdentity, let parent = byID[parentID],
                      parent.ownerUID == candidate.ownerUID,
                      parent.executablePath.flatMap(applicationBundlePath) == bundlePath {
                    root = parent
                }
                let metadata = bundleMetadata(at: bundlePath)
                return (root, bundlePath, metadata.bundleID, metadata.title)
            }
            guard let parentID = candidate.parentIdentity, let parent = byID[parentID],
                  parent.ownerUID == candidate.ownerUID else { break }
            current = parent
        }
        return nil
    }

    private func bundleMetadata(at bundlePath: String) -> CachedBundleMetadata {
        if let cached = bundleMetadataCache[bundlePath] { return cached }
        let bundle = Bundle(url: URL(fileURLWithPath: bundlePath))
        let bundleID = bundle?.bundleIdentifier
        let defaultTitle = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        let title = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? defaultTitle
        let metadata = CachedBundleMetadata(bundleID: bundleID, title: title)
        if bundleMetadataOrder.count >= Self.bundleMetadataCacheLimit {
            let evicted = bundleMetadataOrder.removeFirst()
            bundleMetadataCache.removeValue(forKey: evicted)
        }
        bundleMetadataOrder.append(bundlePath)
        bundleMetadataCache[bundlePath] = metadata
        return metadata
    }

    /// Executable paths come from processPath, which already standardizes them, so they are only split here.
    /// Results are memoized per path; the cache is cleared whole when it reaches its size cap.
    private func applicationBundlePath(_ executablePath: String) -> String? {
        if let cached = applicationBundlePathCache[executablePath] { return cached }
        let components = (executablePath as NSString).pathComponents
        var bundlePath: String?
        if let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            bundlePath = NSString.path(withComponents: Array(components.prefix(index + 1)))
        }
        if applicationBundlePathCache.count >= Self.applicationBundlePathCacheLimit {
            applicationBundlePathCache.removeAll(keepingCapacity: true)
        }
        applicationBundlePathCache[executablePath] = .some(bundlePath)
        return bundlePath
    }

    private func historyIdentity(for process: ProcessSnapshot,
                                 association: ProcessGroupAssociation) -> ApplicationHistoryIdentity {
        let path = process.executablePath
        let stable = path.map { "executable:\($0)" }
            ?? "process:\(process.id.pid):\(process.id.startTime.secondsSinceEpoch):\(process.id.startTime.microseconds)"
        return ApplicationHistoryIdentity(id: stable, name: process.name,
                                          executablePath: path, association: association)
    }

    private func isLaunchd(_ process: ProcessSnapshot) -> Bool {
        process.executablePath == "/sbin/launchd" || process.name == "launchd"
    }

    private static func missingAdvancedReading(_ kind: MetricKind, unit: MetricUnit, timestamp: Date,
                                               snapshot: AdvancedMetricsSnapshot,
                                               hasProvider: Bool) -> MetricReading {
        if let capability = snapshot.capabilities[kind], !capability.available {
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: capability.reason ?? .notCollected, detail: capability.detail)
        }
        return MetricReading(unavailable: unit, timestamp: timestamp,
                             reason: hasProvider ? .notCollected : .unsupported)
    }

    private static func fixedCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    nonisolated static func combineRates(_ readings: [MetricReading], unit: MetricUnit,
                                         timestamp: Date) -> MetricReading {
        guard !readings.isEmpty else {
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .notCollected)
        }
        let availableValues = readings.compactMap(\.value)
        let unavailableCount = readings.count - availableValues.count
        var isPartial = readings.contains(where: \.isPartial)
            || (!availableValues.isEmpty && unavailableCount > 0)
        guard !availableValues.isEmpty else {
            let unavailableReadings = readings.filter { !$0.isAvailable }
            let unavailable = unavailableReadings.first(where: {
                $0.unavailableReason == .permissionDenied
                    || $0.unavailableReason == .collectionFailed
                    || $0.unavailableReason == .sleepGap
            }) ?? unavailableReadings.first(where: { $0.unavailableReason == .counterReset })
                ?? unavailableReadings.first(where: {
                    $0.unavailableReason == .processExited || $0.unavailableReason == .identityChanged
                }) ?? unavailableReadings.first
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: unavailable?.unavailableReason ?? .collectionFailed,
                                 detail: unavailable?.detail, isPartial: isPartial)
        }
        let total = availableValues.reduce(0, +)
        let availableReadings = readings.filter(\.isAvailable)
        let measurementInterval: DateInterval?
        if let firstInterval = availableReadings.first?.measurementInterval,
           availableReadings.allSatisfy({ $0.measurementInterval == firstInterval }) {
            measurementInterval = firstInterval
        } else {
            measurementInterval = nil
        }
        let hasExplicitMeasurementInterval = availableReadings.contains { $0.measurementInterval != nil }
        let hasIncompatibleMeasurementIntervals = hasExplicitMeasurementInterval && measurementInterval == nil
        if hasIncompatibleMeasurementIntervals { isPartial = true }
        var details = readings.compactMap(\.detail)
        if unavailableCount > 0 {
            details.append("Partial: \(unavailableCount) of \(readings.count) members unavailable")
        }
        if hasIncompatibleMeasurementIntervals {
            details.append("Some rate contributors have missing or incompatible measurement intervals")
        }
        var seenDetails = Set<String>()
        let detail = details.filter { seenDetails.insert($0).inserted }.joined(separator: "; ")
        return MetricReading(value: total, unit: unit, timestamp: timestamp,
                             detail: detail.isEmpty ? nil : detail, isPartial: isPartial,
                             measurementInterval: measurementInterval)
    }

    private func startMemoryPressureSourceIfNeeded() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let rawEvents = source?.data.rawValue else { return }
            Task { await self?.receiveMemoryPressure(rawEvents) }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func receiveMemoryPressure(_ rawEvents: UInt) {
        let events = DispatchSource.MemoryPressureEvent(rawValue: rawEvents)
        if events.contains(.critical) { pressureLevel = .critical }
        else if events.contains(.warning) { pressureLevel = .warning }
        else if events.contains(.normal) { pressureLevel = .normal }
        pressureTimestamp = Date()
    }

    private func discoverLaunchEntries(processes: [ProcessSnapshot], at timestamp: Date) -> LaunchDiscoveryResult {
        let refreshInterval: TimeInterval = 30
        if let cachedLaunchDiscovery {
            let age = timestamp.timeIntervalSince(cachedLaunchDiscovery.refreshedAt)
            if age >= 0, age < refreshInterval {
                let runningPaths = Set(processes.compactMap(\.executablePath))
                func refreshState(_ entries: [DiscoveredEntrySnapshot]) -> [DiscoveredEntrySnapshot] {
                    entries.map { entry in
                        let isRunning = cachedLaunchDiscovery.result.programPaths[entry.id]
                            .map(runningPaths.contains) ?? false
                        return DiscoveredEntrySnapshot(id: entry.id, kind: entry.kind, name: entry.name,
                                                       path: entry.path, ownerUID: entry.ownerUID,
                                                       state: isRunning ? .running : .unknown,
                                                       detail: entry.detail)
                    }
                }
                return LaunchDiscoveryResult(
                    startupItems: refreshState(cachedLaunchDiscovery.result.startupItems),
                    services: refreshState(cachedLaunchDiscovery.result.services),
                    startupCoverage: cachedLaunchDiscovery.result.startupCoverage,
                    serviceCoverage: cachedLaunchDiscovery.result.serviceCoverage,
                    programPaths: cachedLaunchDiscovery.result.programPaths)
            }
        }
        let result = LaunchDiscovery.collect(processes: processes)
        cachedLaunchDiscovery = CachedLaunchDiscovery(refreshedAt: timestamp, result: result)
        return result
    }

    private func discoverUsers(at timestamp: Date) -> UserDiscoveryResult {
        let refreshInterval: TimeInterval = 20
        if let cachedUserDiscovery {
            let age = timestamp.timeIntervalSince(cachedUserDiscovery.refreshedAt)
            if age >= 0, age < refreshInterval { return cachedUserDiscovery.result }
        }
        let result = UserDiscovery.collect()
        cachedUserDiscovery = CachedUserDiscovery(refreshedAt: timestamp, result: result)
        return result
    }

    static func memoryBreakdown(physicalBytes: UInt64, pageBytes: UInt64,
                                internalPages: UInt64, purgeablePages: UInt64,
                                wirePages: UInt64, compressorPages: UInt64) -> (usedBytes: UInt64, availableBytes: UInt64) {
        let nonReclaimableInternal = internalPages - min(internalPages, purgeablePages)
        let usedPages = nonReclaimableInternal + wirePages + compressorPages
        let (rawUsedBytes, overflow) = usedPages.multipliedReportingOverflow(by: pageBytes)
        let usedBytes = overflow ? physicalBytes : min(physicalBytes, rawUsedBytes)
        return (usedBytes, physicalBytes - usedBytes)
    }

    /// Capability for a discovery source. An incomplete source carries its reasons as the detail.
    private static func availability(for coverage: DiscoveryCoverage) -> MetricAvailability {
        guard !coverage.complete else { return MetricAvailability(available: true) }
        let joined = coverage.reasons.joined(separator: "; ")
        let detail = joined.isEmpty ? "Collection was incomplete." : joined
        let limit = 600
        let shortened = detail.count > limit ? String(detail.prefix(limit)) + "..." : detail
        return MetricAvailability(available: false, reason: .collectionFailed, detail: shortened)
    }

    private static func availability(for reading: MetricReading?) -> MetricAvailability {
        guard let reading else { return MetricAvailability(available: false, reason: .notCollected) }
        return MetricAvailability(available: reading.isAvailable,
                                  reason: reading.unavailableReason, detail: reading.detail)
    }

    private static func availability(for readings: [MetricReading]) -> MetricAvailability {
        guard !readings.isEmpty else { return MetricAvailability(available: false, reason: .notCollected) }
        guard readings.allSatisfy(\.isAvailable) else {
            let unavailable = readings.first(where: { !$0.isAvailable })
            return MetricAvailability(available: false, reason: unavailable?.unavailableReason ?? .collectionFailed,
                                      detail: unavailable?.detail)
        }
        return MetricAvailability(available: true)
    }
}
