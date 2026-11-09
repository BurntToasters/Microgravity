import Darwin
import Foundation
import IOKit

/// Splits logical processors into core classes using the performance levels sysctl reports and the
/// cluster type of each CPU in the device tree. Every failure yields nil, which callers show as one ungrouped list.
enum ProcessorTopologyReader {
    /// Largest performance-level count accepted, so a corrupt value cannot drive a long loop.
    private static let maximumPerformanceLevels: Int32 = 16

    /// Reads this Mac's topology. Nil on single-class hardware, when a source is missing, or when the sources disagree.
    static func read() -> ProcessorTopology? {
        guard let levelCount = sysctlInt32("hw.nperflevels"), levelCount >= 2,
              levelCount <= maximumPerformanceLevels,
              let logicalCPUCount = sysctlInt32("hw.logicalcpu"), logicalCPUCount > 0 else { return nil }

        var levels: [(name: String, logicalCount: Int)] = []
        for index in 0..<Int(levelCount) {
            guard let name = sysctlString("hw.perflevel\(index).name"),
                  let count = sysctlInt32("hw.perflevel\(index).logicalcpu") else { return nil }
            levels.append((name: name, logicalCount: Int(count)))
        }
        guard let cpus = deviceTreeCPUs() else { return nil }
        return resolve(perfLevels: levels, cpus: cpus, logicalCPUCount: Int(logicalCPUCount))
    }

    /// Cluster-type letters in strength order, strongest first. The order comes from known Apple silicon:
    /// on M5 Pro "P" is Super and "M" is Performance; on M1 through M4 "P" is Performance and "E" is Efficiency.
    private static let knownClusterTypeOrder = ["P", "M", "E"]

    /// Pure resolver. Performance levels are in sysctl order, fastest first. Every logical ID in
    /// 0..<logicalCPUCount must appear exactly once, and there must be at least two levels.
    /// When every cluster-type letter is known, groups sorted by `knownClusterTypeOrder` pair with levels in rank
    /// order, and each pair's size must equal that level's logical CPU count. Otherwise each group must match
    /// exactly one level by count, and equal counts on either side resolve to nil.
    static func resolve(perfLevels: [(name: String, logicalCount: Int)],
                        cpus: [(logicalID: Int, clusterType: String)],
                        logicalCPUCount: Int) -> ProcessorTopology? {
        guard perfLevels.count >= 2, logicalCPUCount > 0, cpus.count == logicalCPUCount else { return nil }
        guard Set(cpus.map(\.logicalID)).count == logicalCPUCount,
              cpus.allSatisfy({ (0..<logicalCPUCount).contains($0.logicalID) }) else { return nil }
        guard perfLevels.allSatisfy({ !$0.name.isEmpty && $0.logicalCount > 0 }) else { return nil }

        var groups: [String: [Int]] = [:]
        for cpu in cpus {
            guard !cpu.clusterType.isEmpty else { return nil }
            groups[cpu.clusterType, default: []].append(cpu.logicalID)
        }
        guard groups.count == perfLevels.count else { return nil }

        if groups.keys.allSatisfy({ knownClusterTypeOrder.contains($0) }) {
            let ordered = groups
                .map { (strength: knownClusterTypeOrder.firstIndex(of: $0.key) ?? 0, ids: $0.value) }
                .sorted { $0.strength < $1.strength }
            var kinds: [ProcessorCoreKind] = []
            for (rank, level) in perfLevels.enumerated() {
                let group = ordered[rank]
                guard group.ids.count == level.logicalCount else { return nil }
                kinds.append(ProcessorCoreKind(name: level.name, rank: rank, logicalCPUs: group.ids.sorted()))
            }
            return ProcessorTopology(kinds: kinds)
        }

        let groupCounts = groups.values.map(\.count)
        let levelCounts = perfLevels.map(\.logicalCount)
        guard Set(groupCounts).count == groupCounts.count,
              Set(levelCounts).count == levelCounts.count,
              Set(groupCounts) == Set(levelCounts) else { return nil }

        var kinds: [ProcessorCoreKind] = []
        for (rank, level) in perfLevels.enumerated() {
            guard let logicalIDs = groups.values.first(where: { $0.count == level.logicalCount })?.sorted() else {
                return nil
            }
            kinds.append(ProcessorCoreKind(name: level.name, rank: rank, logicalCPUs: logicalIDs))
        }
        return ProcessorTopology(kinds: kinds)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Reads logical-cpu-id and cluster-type from each CPU node. Other children of the cpus node are skipped.
    /// A CPU node missing either property is left out, so the count check in `resolve` rejects the result.
    private static func deviceTreeCPUs() -> [(logicalID: Int, clusterType: String)]? {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, "IODeviceTree", &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var cpus: [(logicalID: Int, clusterType: String)] = []
        var visited = 0
        while visited < 1_024 {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            visited += 1

            guard let logicalID = registryProperty(entry, "logical-cpu-id") as? NSNumber,
                  let clusterData = registryProperty(entry, "cluster-type") as? Data else { continue }
            let clusterType = String(decoding: clusterData.filter { $0 != 0 }, as: UTF8.self)
            cpus.append((logicalID: logicalID.intValue, clusterType: clusterType))
        }
        return cpus.isEmpty ? nil : cpus
    }

    private static func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
