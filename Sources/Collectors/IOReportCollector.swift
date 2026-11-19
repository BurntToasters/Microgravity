import CoreFoundation
import Darwin
import Foundation

struct IOReportReading: Equatable, Sendable {
    let gpuUtilizationPercent: Double?
    let components: ComponentPowerReadings?
    let interval: DateInterval
}

/// Dynamic, unprivileged Apple Silicon `libIOReport.dylib` collector for 1s GPU utilization and SoC power.
final class IOReportCollector: @unchecked Sendable {
    #if arch(arm64)
    private typealias CopyChannelsInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannelsFn = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscriptionFn = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        CFTypeRef?
    ) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleGetIntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private struct Symbols {
        let handle: UnsafeMutableRawPointer
        let copyChannelsInGroup: CopyChannelsInGroupFn
        let mergeChannels: MergeChannelsFn
        let createSubscription: CreateSubscriptionFn
        let createSamples: CreateSamplesFn
        let createSamplesDelta: CreateSamplesDeltaFn
        let iterate: IterateFn
        let channelGetGroup: GetStringFn
        let channelGetSubGroup: GetStringFn
        let channelGetName: GetStringFn
        let channelGetUnitLabel: GetStringFn
        let simpleGetInt: SimpleGetIntFn
        let stateGetCount: StateGetCountFn
        let stateGetName: StateGetNameFn
        let stateGetResidency: StateGetResidencyFn
    }

    private let lock = NSLock()
    private var symbols: Symbols?
    private var subscription: CFTypeRef?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTimestamp: Date?
    private var initializationFailed = false

    deinit {
        lock.lock()
        previousSample = nil
        subscribedChannels = nil
        subscription = nil
        if let handle = symbols?.handle {
            dlclose(handle)
        }
        symbols = nil
        lock.unlock()
    }
    #endif

    var hasHardwareChannels: Bool {
        #if arch(arm64)
        lock.lock()
        defer { lock.unlock() }
        if subscription == nil && !initializationFailed {
            if !initializeLocked() {
                initializationFailed = true
            }
        }
        return subscription != nil && !initializationFailed
        #else
        return false
        #endif
    }

    func sample(at timestamp: Date) -> IOReportReading? {
        #if arch(arm64)
        lock.lock()
        defer { lock.unlock() }

        guard !initializationFailed else { return nil }
        if subscription == nil {
            guard initializeLocked() else {
                initializationFailed = true
                return nil
            }
        }
        guard let symbols,
              let subscription,
              let subscribedChannels,
              let currentSample = symbols.createSamples(
                  Unmanaged.passUnretained(subscription).toOpaque(),
                  subscribedChannels,
                  nil
              )?.takeRetainedValue() else {
            return nil
        }

        defer {
            previousSample = currentSample
            previousTimestamp = timestamp
        }

        guard let previousSample,
              let previousTimestamp,
              timestamp > previousTimestamp else {
            return nil
        }

        let elapsed = timestamp.timeIntervalSince(previousTimestamp)
        guard elapsed > 0.05,
              let delta = symbols.createSamplesDelta(previousSample, currentSample, nil)?.takeRetainedValue() else {
            return nil
        }

        let interval = DateInterval(start: previousTimestamp, end: timestamp)
        return Self.parseDelta(delta, elapsed: elapsed, interval: interval, symbols: symbols)
        #else
        return nil
        #endif
    }

    #if arch(arm64)
    private func initializeLocked() -> Bool {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else { return false }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }

        guard let copyGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self),
              let merge = load("IOReportMergeChannels", as: MergeChannelsFn.self),
              let createSub = load("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamplesFn.self),
              let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
              let iterate = load("IOReportIterate", as: IterateFn.self),
              let getGroup = load("IOReportChannelGetGroup", as: GetStringFn.self),
              let getSubGroup = load("IOReportChannelGetSubGroup", as: GetStringFn.self),
              let getName = load("IOReportChannelGetChannelName", as: GetStringFn.self),
              let getUnit = load("IOReportChannelGetUnitLabel", as: GetStringFn.self),
              let simpleInt = load("IOReportSimpleGetIntegerValue", as: SimpleGetIntFn.self),
              let stateCount = load("IOReportStateGetCount", as: StateGetCountFn.self),
              let stateName = load("IOReportStateGetNameForIndex", as: StateGetNameFn.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateGetResidencyFn.self) else {
            dlclose(handle)
            return false
        }

        let energy = copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        let gpu = copyGroup("GPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue()

        let combined: CFMutableDictionary
        if let energy, let gpu {
            merge(energy, gpu, nil)
            combined = energy
        } else if let only = energy ?? gpu {
            combined = only
        } else {
            dlclose(handle)
            return false
        }

        guard CFDictionaryGetCount(combined) > 0 else {
            dlclose(handle)
            return false
        }

        var subbedRef: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, combined, &subbedRef, 0, nil)?.takeRetainedValue(),
              let subDict = subbedRef?.takeRetainedValue() else {
            dlclose(handle)
            return false
        }

        symbols = Symbols(
            handle: handle,
            copyChannelsInGroup: copyGroup,
            mergeChannels: merge,
            createSubscription: createSub,
            createSamples: createSamples,
            createSamplesDelta: createSamplesDelta,
            iterate: iterate,
            channelGetGroup: getGroup,
            channelGetSubGroup: getSubGroup,
            channelGetName: getName,
            channelGetUnitLabel: getUnit,
            simpleGetInt: simpleInt,
            stateGetCount: stateCount,
            stateGetName: stateName,
            stateGetResidency: stateResidency
        )
        subscription = sub
        subscribedChannels = subDict
        return true
    }

    private static func parseDelta(_ delta: CFDictionary,
                                   elapsed: TimeInterval,
                                   interval: DateInterval,
                                   symbols: Symbols) -> IOReportReading? {
        var exactCPUJoules: Double?
        var fallbackClusterCPUJoules = 0.0
        var hasClusterCPU = false
        var gpuJoules: Double?
        var exactANEJoules: Double?
        var aneSubJoules = 0.0
        var hasANESub = false
        var dramJoules: Double?
        var gpuPercent: Double?

        symbols.iterate(delta) { channel in
            let group = symbols.channelGetGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let subgroup = symbols.channelGetSubGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = symbols.channelGetName(channel)?.takeUnretainedValue() as String? ?? ""
            let unit = symbols.channelGetUnitLabel(channel)?.takeUnretainedValue() as String? ?? ""

            if group == "Energy Model" {
                let raw = symbols.simpleGetInt(channel, 0)
                if raw >= 0, let joules = convertEnergyToJoules(Double(raw), unit: unit) {
                    let upper = name.uppercased()
                    if upper == "CPU ENERGY" || upper == "CPU" {
                        exactCPUJoules = (exactCPUJoules ?? 0) + joules
                    } else if upper.hasPrefix("ECPU") || upper.hasPrefix("PCPU") {
                        hasClusterCPU = true
                        fallbackClusterCPUJoules += joules
                    } else if upper == "GPU ENERGY" || upper == "GPU" {
                        gpuJoules = (gpuJoules ?? 0) + joules
                    } else if upper == "ANE ENERGY" || upper == "ANE" {
                        exactANEJoules = (exactANEJoules ?? 0) + joules
                    } else if upper.hasPrefix("ANE") {
                        hasANESub = true
                        aneSubJoules += joules
                    } else if upper == "DRAM" || upper == "DRAM ENERGY" {
                        dramJoules = (dramJoules ?? 0) + joules
                    }
                }
            } else if group == "GPU Stats", subgroup == "GPU Performance States" {
                let count = symbols.stateGetCount(channel)
                if count > 0, name == "GPUPH" || gpuPercent == nil {
                    var totalResidency: Int64 = 0
                    var idleResidency: Int64 = 0
                    for idx in 0..<count {
                        let residency = max(0, symbols.stateGetResidency(channel, idx))
                        totalResidency += residency
                        let stateTitle = (symbols.stateGetName(channel, idx)?.takeUnretainedValue() as String? ?? "").uppercased()
                        if stateTitle.contains("OFF") || stateTitle.contains("IDLE") || stateTitle.contains("DOWN") {
                            idleResidency += residency
                        }
                    }
                    if totalResidency > 0 {
                        let active = Double(totalResidency - idleResidency)
                        gpuPercent = min(100, max(0, (active / Double(totalResidency)) * 100.0))
                    }
                }
            }
            return 0
        }

        let cpuW = (exactCPUJoules ?? (hasClusterCPU ? fallbackClusterCPUJoules : nil)).map { $0 / elapsed }
        let gpuW = gpuJoules.map { $0 / elapsed }
        let aneW = (exactANEJoules ?? (hasANESub ? aneSubJoules : nil)).map { $0 / elapsed }
        let dramW = dramJoules.map { $0 / elapsed }

        let components: ComponentPowerReadings?
        if cpuW != nil || gpuW != nil || aneW != nil || dramW != nil {
            components = ComponentPowerReadings(cpuWatts: cpuW, gpuWatts: gpuW, aneWatts: aneW, dramWatts: dramW,
                                                interval: interval, detail: "SoC Component Power (IOReport)")
        } else {
            components = nil
        }

        guard gpuPercent != nil || components != nil else { return nil }
        return IOReportReading(gpuUtilizationPercent: gpuPercent, components: components, interval: interval)
    }

    private static func convertEnergyToJoules(_ value: Double, unit: String) -> Double? {
        let normalized = unit.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "nj": return value * 1e-9
        case "uj": return value * 1e-6
        case "mj": return value * 1e-3
        case "j": return value
        default: return nil
        }
    }
    #endif
}
