import Darwin
import Foundation
import IOKit
import Metal

/// Reads largely static machine hardware descriptors once and caches them across ticks.
final class HardwareSpecReader: @unchecked Sendable {
    typealias NetworkDetailLookup = @Sendable (String) -> String?
    typealias Clock = @Sendable () -> Date

    /// How long a per-interface network detail stays cached before the IOKit lookup runs again.
    static let networkDetailTTL: TimeInterval = 30

    private struct CachedNetworkDetail {
        let value: String?
        let fetchedAt: Date
    }

    private let lock = NSLock()
    private var cachedSpec: HardwareSpecSnapshot?
    private var networkDetailCache: [String: CachedNetworkDetail] = [:]
    private let networkDetailLookup: NetworkDetailLookup
    private let now: Clock

    convenience init() {
        self.init(
            networkDetailLookup: { HardwareSpecReader.networkDetail(for: $0) },
            now: { Date() }
        )
    }

    /// Test seam: injects the network detail lookup and the clock used for the detail cache TTL.
    init(networkDetailLookup: @escaping NetworkDetailLookup, now: @escaping Clock) {
        self.networkDetailLookup = networkDetailLookup
        self.now = now
    }

    func read(primaryNetworkInterface: NetworkInterfaceSnapshot? = nil) -> HardwareSpecSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let base: HardwareSpecSnapshot
        if let cachedSpec {
            base = cachedSpec
        } else {
            let discovered = Self.discoverBaseSpec()
            cachedSpec = discovered
            base = discovered
        }

        let activeNIC = primaryNetworkInterface?.name ?? base.primaryNetworkInterface
        let activeNICDetail = cachedNetworkDetailLocked(for: activeNIC) ?? base.primaryNetworkDetail
        return HardwareSpecSnapshot(
            machineModel: base.machineModel,
            cpuName: base.cpuName,
            gpuName: base.gpuName,
            gpuCoreCount: base.gpuCoreCount,
            memorySummary: base.memorySummary,
            bootDiskModel: base.bootDiskModel,
            bootDiskCapacityBytes: base.bootDiskCapacityBytes,
            primaryNetworkInterface: activeNIC,
            primaryNetworkDetail: activeNICDetail
        )
    }

    private static func discoverBaseSpec() -> HardwareSpecSnapshot {
        let model = sysctlString("hw.model")
        let cpu = sysctlString("machdep.cpu.brand_string")
        let gpuInfo = readGPUInfo()
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        let memorySummary = formatRAMSize(memoryBytes)
        let bootDisk = readBootDiskInfo()
        return HardwareSpecSnapshot(
            machineModel: model,
            cpuName: cpu,
            gpuName: gpuInfo.name,
            gpuCoreCount: gpuInfo.coreCount,
            memorySummary: memorySummary,
            bootDiskModel: bootDisk.model,
            bootDiskCapacityBytes: bootDisk.capacityBytes,
            primaryNetworkInterface: nil,
            primaryNetworkDetail: nil
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let trimmed = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatRAMSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if abs(gb.rounded() - gb) < 0.05 {
            return "\(Int(gb.rounded())) GB"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private static func readGPUInfo() -> (name: String?, coreCount: Int?) {
        var name: String?
        var coreCount: Int?

        // The IORegistry already carries the GPU model and core count, so Metal is only a fallback.
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                if let coresRef = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                   coresRef.intValue > 0 {
                    coreCount = coresRef.intValue
                }
                if name == nil,
                   let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    name = model
                }
            }
        }

        if name == nil {
            name = metalFallbackGPUName()
        }
        return (name, coreCount)
    }

    /// Metal fallback. Prefers the integrated GPU so that reading the name never asks macOS to
    /// switch to the discrete GPU on dual-GPU Macs. `MTLCreateSystemDefaultDevice()` is only used
    /// when no low-power device is listed.
    private static func metalFallbackGPUName() -> String? {
        let candidates = MTLCopyAllDevices().map { (name: $0.name, isLowPower: $0.isLowPower) }
        if let integrated = lowPowerGPUName(from: candidates) {
            return integrated
        }
        return MTLCreateSystemDefaultDevice()?.name
    }

    /// Returns the name of the first low-power device in the list, or nil when there is none.
    static func lowPowerGPUName(from devices: [(name: String, isLowPower: Bool)]) -> String? {
        devices.first(where: { $0.isLowPower })?.name
    }

    private static func readBootDiskInfo() -> (model: String?, capacityBytes: UInt64?) {
        let rootURL = URL(fileURLWithPath: "/")
        let values = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeNameKey])
        let capacity = values?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        var diskModel: String?

        var fsStat = statfs()
        if statfs("/", &fsStat) == 0 {
            let devPath = withUnsafePointer(to: fsStat.f_mntfromname) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let bsdRaw = devPath.replacingOccurrences(of: "/dev/", with: "")
            let wholeDiskBSD = stripPartitionSuffix(bsdRaw)
            if let matching = IOBSDNameMatching(kIOMainPortDefault, 0, wholeDiskBSD) {
                let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                if media != 0 {
                    defer { IOObjectRelease(media) }
                    diskModel = walkUpForProductName(from: media)
                }
            }
        }

        if diskModel == nil {
            diskModel = values?.volumeName
        }
        return (diskModel, capacity)
    }

    private static func stripPartitionSuffix(_ name: String) -> String {
        // Turn e.g. "disk3s1s1" or "disk3s5" into whole-disk "disk3".
        guard name.hasPrefix("disk") else { return name }
        let suffix = name.dropFirst(4)
        if let sIndex = suffix.firstIndex(of: "s") {
            return "disk" + suffix[..<sIndex]
        }
        return name
    }

    private static func walkUpForProductName(from service: io_registry_entry_t) -> String? {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        for _ in 0..<12 {
            if let characteristics = IORegistryEntryCreateCFProperty(
                current, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
               let product = characteristics["Product Name"] as? String {
                let trimmed = product.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    IOObjectRelease(current)
                    return trimmed
                }
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS, parent != 0 else {
                current = 0
                break
            }
            current = parent
        }
        if current != 0 {
            IOObjectRelease(current)
        }
        return nil
    }

    /// Returns the cached detail for an interface, running the lookup again once the TTL has passed.
    /// Must be called with `lock` held.
    private func cachedNetworkDetailLocked(for interfaceName: String?) -> String? {
        guard let interfaceName, !interfaceName.isEmpty else { return nil }
        let current = now()
        if let entry = networkDetailCache[interfaceName] {
            let age = current.timeIntervalSince(entry.fetchedAt)
            if age >= 0, age < Self.networkDetailTTL {
                return entry.value
            }
        }
        let value = networkDetailLookup(interfaceName)
        networkDetailCache[interfaceName] = CachedNetworkDetail(value: value, fetchedAt: current)
        return value
    }

    private static func networkDetail(for interfaceName: String?) -> String? {
        guard let interfaceName, !interfaceName.isEmpty else { return nil }
        if interfaceName.hasPrefix("en"),
           let matching = IOBSDNameMatching(kIOMainPortDefault, 0, interfaceName) {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if service != 0 {
                defer { IOObjectRelease(service) }
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                    defer { IOObjectRelease(parent) }
                    if let nameData = IORegistryEntryCreateCFProperty(parent, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       nameData.lowercased().contains("wifi") || nameData.lowercased().contains("airport") || nameData.lowercased().contains("80211") {
                        return String(localized: "Wi-Fi")
                    }
                    if let speed = IORegistryEntryCreateCFProperty(parent, "IOLinkSpeed" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                       speed.uint64Value > 0 {
                        let mbps = speed.uint64Value / 1_000_000
                        return mbps >= 1000 ? "\(mbps / 1000) Gbps" : "\(mbps) Mbps"
                    }
                }
            }
        }
        return nil
    }
}
