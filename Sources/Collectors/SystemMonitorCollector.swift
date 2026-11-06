import Darwin
import Dispatch
import Foundation
import IOKit
import IOKit.storage
import MachO
import SystemConfiguration

public actor SystemMonitorCollector: MonitoringCollecting {
    private enum CounterKey: Hashable {
        case coreTotal(Int)
        case coreActive(Int)
        case diskRead
        case diskWrite
        case networkReceive(String)
        case networkTransmit(String)
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

    private struct CachedBundleMetadata {
        let bundleID: String?
        let title: String
    }

    private static let bundleMetadataCacheLimit = 256

    private let advancedCollector: (any AdvancedMetricsCollecting)?
    private var systemCounters = CounterDeltaTracker<CounterKey>()
    private var processCounters = CounterDeltaTracker<ProcessCounterKey>()
    private var interfaceNames = Set<String>()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pressureLevel: MemoryPressureLevel?
    private var pressureTimestamp: Date?
    private var cachedLaunchDiscovery: CachedLaunchDiscovery?
    private var bundleMetadataCache: [String: CachedBundleMetadata] = [:]
    private var bundleMetadataOrder: [String] = []

    public init(advancedCollector: (any AdvancedMetricsCollecting)? = nil) {
        self.advancedCollector = advancedCollector
    }

    public func collect(at timestamp: Date) async -> MonitoringSnapshot {
        startMemoryPressureSourceIfNeeded()

        let cpu = collectCPU(at: timestamp)
        let memory = collectMemory(at: timestamp)
        let disk = collectDisk(at: timestamp)
        let network = collectNetwork(at: timestamp)
        let processResult = collectProcesses(at: timestamp, capacityCores: cpu.capacityCores)
        let rawProcesses = processResult.processes
        let baseProcesses = linkProcesses(rawProcesses)
        let advanced = await advancedCollector?.collectAdvancedMetrics(at: timestamp) ?? AdvancedMetricsSnapshot()
        let processes = baseProcesses.map { process in
            var values = advanced.perProcess[process.id] ?? [:]
            if values[.processGPUTime] == nil {
                values[.processGPUTime] = MetricReading(unavailable: .seconds, timestamp: timestamp,
                                                        reason: .unsupported)
            }
            if values[.processNetwork] == nil {
                values[.processNetwork] = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                        reason: .unsupported)
            }
            if values[.processNetworkReceive] == nil {
                values[.processNetworkReceive] = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                               reason: .unsupported)
            }
            if values[.processNetworkTransmit] == nil {
                values[.processNetworkTransmit] = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                               reason: .unsupported)
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
        let sessions = discoverUsers()

        var advancedReadings = advanced.system
        if advancedReadings[.gpu] == nil {
            advancedReadings[.gpu] = MetricReading(unavailable: .percent, timestamp: timestamp,
                                                   reason: .unsupported)
        }
        if advancedReadings[.energy] == nil {
            advancedReadings[.energy] = MetricReading(unavailable: .joules, timestamp: timestamp,
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
                                          detail: processResult.complete ? nil : "Process enumeration was capped or incomplete."),
            .processIO: Self.availability(for: processes.first?.diskReadBytesPerSecond),
            .startupItems: MetricAvailability(available: inventory.startupCoverage.complete,
                                              reason: inventory.startupCoverage.complete ? nil : .collectionFailed),
            .services: MetricAvailability(available: inventory.serviceCoverage.complete,
                                          reason: inventory.serviceCoverage.complete ? nil : .collectionFailed),
            .userSessions: MetricAvailability(available: sessions.coverage.complete,
                                              reason: sessions.coverage.complete ? nil : .collectionFailed),
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
                                           reasons: processResult.complete ? [] : ["Process enumeration reached its bounded limit or a process exited during collection."]),
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
            let pageBytes = UInt64(pageSize)
            let availablePages = UInt64(stats.free_count) + UInt64(stats.speculative_count)
            let availableBytes = min(physicalBytes, availablePages * pageBytes)
            memoryAvailable = MetricReading(value: Double(availableBytes), unit: .bytes, timestamp: timestamp)
            memoryTotal = MetricReading(value: Double(physicalBytes), unit: .bytes, timestamp: timestamp)
            memoryUsed = MetricReading(value: Double(physicalBytes - availableBytes), unit: .bytes, timestamp: timestamp)
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

        let pressure: MemoryPressureSnapshot
        if let pressureLevel, let pressureTimestamp {
            pressure = MemoryPressureSnapshot(level: pressureLevel, timestamp: pressureTimestamp)
        } else {
            pressure = MemoryPressureSnapshot(unavailable: timestamp, reason: .notCollected)
        }
        return (memoryUsed, memoryAvailable, memoryTotal, pressure, swapUsed, swapTotal)
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
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            clearNetworkBaselines()
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed, detail: "getifaddrs failed: \(errno)")
            return (unavailable, unavailable, [])
        }
        defer { freeifaddrs(addresses) }
        var records: [String: (isUp: Bool, receive: UInt64, transmit: UInt64)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            if let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
               let rawData = item.ifa_data, let namePointer = item.ifa_name {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                let name = String(cString: namePointer)
                records[name] = (UInt32(item.ifa_flags) & UInt32(IFF_UP) != 0,
                                 UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
            }
            cursor = item.ifa_next
        }
        let activeKeys = Set(records.keys)
        for name in interfaceNames.subtracting(activeKeys) {
            systemCounters.remove(.networkReceive(name))
            systemCounters.remove(.networkTransmit(name))
        }
        interfaceNames = activeKeys
        guard !records.isEmpty else {
            clearNetworkBaselines()
            let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                            reason: .collectionFailed, detail: "No network interface counters found")
            return (unavailable, unavailable, [])
        }

        var interfaces: [NetworkInterfaceSnapshot] = []
        for (name, data) in records.sorted(by: { $0.key < $1.key }) {
            let receiveResult = systemCounters.update(data.receive, for: .networkReceive(name), at: timestamp)
            let transmitResult = systemCounters.update(data.transmit, for: .networkTransmit(name), at: timestamp)
            interfaces.append(NetworkInterfaceSnapshot(
                name: name, isUp: data.isUp,
                receiveBytesPerSecond: receiveResult.reading(unit: .bytesPerSecond, timestamp: timestamp) {
                    Double($0) / $1
                },
                transmitBytesPerSecond: transmitResult.reading(unit: .bytesPerSecond, timestamp: timestamp) {
                    Double($0) / $1
                },
                receiveTotalBytes: MetricReading(value: Double(data.receive), unit: .bytes, timestamp: timestamp),
                transmitTotalBytes: MetricReading(value: Double(data.transmit), unit: .bytes, timestamp: timestamp)))
        }
        let receive = Self.combineRates(interfaces.map(\.receiveBytesPerSecond), unit: .bytesPerSecond,
                                        timestamp: timestamp)
        let transmit = Self.combineRates(interfaces.map(\.transmitBytesPerSecond), unit: .bytesPerSecond,
                                         timestamp: timestamp)
        return (receive, transmit, interfaces)
    }

    private func collectProcesses(at timestamp: Date, capacityCores: Int) -> (processes: [RawProcess], complete: Bool) {
        let pidBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidBytes > 0 else { return ([], false) }
        let maximumPIDCount = 16_384
        let requestedCount = min(maximumPIDCount, Int(pidBytes) / MemoryLayout<pid_t>.stride + 64)
        var pids = [pid_t](repeating: 0, count: requestedCount)
        let returnedBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                          Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard returnedBytes > 0 else { return ([], false) }
        let count = min(pids.count, Int(returnedBytes) / MemoryLayout<pid_t>.stride)
        var records: [RawProcess] = []
        records.reserveCapacity(count)
        var identities = Set<ProcessIdentity>()

        for rawPID in pids.prefix(count) where rawPID > 0 {
            guard let bsd = processBSDInfo(rawPID) else { continue }
            let identity = ProcessIdentity(pid: Int32(rawPID),
                                           startTime: ProcessStartTime(secondsSinceEpoch: Int64(bsd.pbi_start_tvsec),
                                                                       microseconds: Int32(bsd.pbi_start_tvusec)))
            var task = proc_taskinfo()
            let taskSize = proc_pidinfo(rawPID, PROC_PIDTASKINFO, 0, &task,
                                        Int32(MemoryLayout<proc_taskinfo>.size))
            let taskAvailable = taskSize == MemoryLayout<proc_taskinfo>.size
            let cpuReading: MetricReading
            if taskAvailable {
                let cpuNanos = task.pti_total_user &+ task.pti_total_system
                let delta = processCounters.update(cpuNanos, for: .cpu(identity), at: timestamp)
                cpuReading = delta.reading(unit: .percent, timestamp: timestamp) { value, elapsed in
                    guard capacityCores > 0 else { return 0 }
                    return Double(value) / elapsed / 1_000_000_000 / Double(capacityCores) * 100
                }
            } else {
                processCounters.remove(.cpu(identity))
                cpuReading = MetricReading(unavailable: .percent, timestamp: timestamp,
                                           reason: errno == EPERM ? .permissionDenied : .collectionFailed)
            }

            var usage = rusage_info_v4()
            var raw: UnsafeMutableRawPointer? = withUnsafeMutablePointer(to: &usage) { UnsafeMutableRawPointer($0) }
            let usageStatus = withUnsafeMutablePointer(to: &raw) { buffer in
                proc_pid_rusage(rawPID, RUSAGE_INFO_V4, buffer)
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

            guard let confirmed = processBSDInfo(rawPID),
                  Int32(rawPID) == identity.pid,
                  ProcessStartTime(secondsSinceEpoch: Int64(confirmed.pbi_start_tvsec),
                                   microseconds: Int32(confirmed.pbi_start_tvusec)) == identity.startTime else {
                processCounters.remove(.cpu(identity))
                processCounters.remove(.diskRead(identity))
                processCounters.remove(.diskWrite(identity))
                continue
            }
            records.append(RawProcess(identity: identity, parentPID: Int32(bsd.pbi_ppid),
                                      name: processName(rawPID) ?? Self.fixedCString(bsd.pbi_name),
                                      path: processPath(rawPID), ownerUID: UInt32(bsd.pbi_uid),
                                      cpu: cpuReading, memory: memoryReading,
                                      diskReadRate: diskReadRate, diskWriteRate: diskWriteRate,
                                      diskReadTotal: diskReadTotal, diskWriteTotal: diskWriteTotal))
            identities.insert(identity)
        }
        processCounters.retain(Set(identities.flatMap {
            [ProcessCounterKey.cpu($0), .diskRead($0), .diskWrite($0)]
        }))
        let complete = Int(pidBytes) / MemoryLayout<pid_t>.stride <= maximumPIDCount
            && count < pids.count
        return (records, complete)
    }

    private func processBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }

    private func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let size = proc_name(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private func linkProcesses(_ raw: [RawProcess]) -> [ProcessSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: raw.map { ($0.identity.pid, $0.identity) })
        let rawByPID = Dictionary(uniqueKeysWithValues: raw.map { ($0.identity.pid, $0) })
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
        let byID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
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

    private func applicationBundlePath(_ executablePath: String) -> String? {
        let components = URL(fileURLWithPath: executablePath).standardizedFileURL.pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(index + 1)))
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

    private func clearNetworkBaselines() {
        for name in interfaceNames {
            systemCounters.remove(.networkReceive(name))
            systemCounters.remove(.networkTransmit(name))
        }
        interfaceNames.removeAll()
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
        guard !availableValues.isEmpty else {
            let unavailable = readings.first(where: { !$0.isAvailable })
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: unavailable?.unavailableReason ?? .collectionFailed,
                                 detail: unavailable?.detail)
        }
        let total = availableValues.reduce(0, +)
        let unavailableCount = readings.count - availableValues.count
        if unavailableCount > 0 {
            return MetricReading(value: total, unit: unit, timestamp: timestamp,
                                 unavailableReason: nil,
                                 detail: "Partial: \(unavailableCount) of \(readings.count) members unavailable")
        }
        return MetricReading(value: total, unit: unit, timestamp: timestamp)
    }

    private func startMemoryPressureSourceIfNeeded() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let events = source?.data else { return }
            Task { await self?.receiveMemoryPressure(events) }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func receiveMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
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

    private func discoverUsers() -> UserDiscoveryResult {
        UserDiscovery.collect()
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

private extension MetricReading {
    init(value: Double, unit: MetricUnit, timestamp: Date,
         unavailableReason: MetricUnavailableReason?, detail: String?) {
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.unavailableReason = unavailableReason
        self.detail = detail
    }
}
