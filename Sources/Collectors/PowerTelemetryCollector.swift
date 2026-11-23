import Foundation
import IOKit
import IOKit.ps

struct SmartBatteryTelemetry: Equatable, Sendable {
    let systemLoadWatts: Double?
    let systemPowerInWatts: Double?
    let adapterPowerWatts: Double?
    let batteryPowerWatts: Double?
    let externalConnected: Bool?
    let isCharging: Bool?
    let batteryPercent: Double?
    let timeRemainingMinutes: Int?
    let voltageMillivolts: Int64?
    let instantAmperageMilliamps: Int64?
    let adapterMaxWatts: Int?
}

struct PowerSourceInfoSnapshot: Equatable, Sendable {
    let powerSource: PowerSourceKind
    let batteryPercent: Double?
    let isCharging: Bool?
    let timeRemainingMinutes: Int?
}

struct ComponentPowerReadings: Equatable, Sendable {
    let cpuWatts: Double?
    let gpuWatts: Double?
    let aneWatts: Double?
    let dramWatts: Double?
    let interval: DateInterval?
    let detail: String?

    var totalWatts: Double? {
        let components = [cpuWatts, gpuWatts, aneWatts, dramWatts].compactMap { $0 }
        guard !components.isEmpty else { return nil }
        return components.reduce(0, +)
    }
}

/// Unprivileged power collector combining AppleSMC, AppleSmartBattery, IOPowerSources, and thermal state.
enum PowerTelemetryCollector {
    static func collect(components: ComponentPowerReadings? = nil, at timestamp: Date = Date()) -> SystemPowerSnapshot {
        let smc = AppleSMCReader.readPower()
        let battery = readSmartBattery()
        let powerSourceInfo = readPowerSourceInfo()
        let thermalState = mapThermalState(ProcessInfo.processInfo.thermalState)
        return reconcile(smc: smc, battery: battery, powerSourceInfo: powerSourceInfo,
                         components: components, thermalState: thermalState, timestamp: timestamp)
    }

    static func mapThermalState(_ state: ProcessInfo.ThermalState) -> SystemThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func reconcile(smc: AppleSMCPowerReading?,
                          battery: SmartBatteryTelemetry?,
                          powerSourceInfo: PowerSourceInfoSnapshot?,
                          components: ComponentPowerReadings?,
                          thermalState: SystemThermalState,
                          timestamp: Date) -> SystemPowerSnapshot {
        let resolvedSource: PowerSourceKind
        if let infoSource = powerSourceInfo?.powerSource, infoSource != .unknown {
            resolvedSource = infoSource
        } else if let external = battery?.externalConnected {
            resolvedSource = external ? .ac : .battery
        } else {
            resolvedSource = .unknown
        }

        let resolvedBatteryPercent = battery?.batteryPercent ?? powerSourceInfo?.batteryPercent
        let resolvedCharging = battery?.isCharging ?? powerSourceInfo?.isCharging
        let resolvedTimeRemaining = battery?.timeRemainingMinutes ?? powerSourceInfo?.timeRemainingMinutes
        let interval = components?.interval

        // System Power priority: SMC PSTR -> SmartBattery SystemLoad -> battery discharge fallback.
        let systemWattsReading: MetricReading?
        if let pstr = smc?.systemTotalWatts, pstr.isFinite, pstr > 0 {
            systemWattsReading = MetricReading(value: pstr, unit: .watts, timestamp: timestamp,
                                               detail: "System Total (SMC)", measurementInterval: interval)
        } else if let load = battery?.systemLoadWatts, load.isFinite, load > 0 {
            systemWattsReading = MetricReading(value: load, unit: .watts, timestamp: timestamp,
                                               detail: "System Load (Battery Telemetry)",
                                               measurementInterval: interval)
        } else if resolvedSource == .battery,
                  let voltageMV = battery?.voltageMillivolts,
                  let ampsMA = battery?.instantAmperageMilliamps,
                  voltageMV > 0, ampsMA < 0 {
            let watts = abs(Double(voltageMV) * Double(ampsMA) / 1_000_000.0)
            if watts.isFinite, watts > 0 {
                systemWattsReading = MetricReading(value: watts, unit: .watts, timestamp: timestamp,
                                                   detail: "Battery Discharge Estimate",
                                                   measurementInterval: interval)
            } else {
                systemWattsReading = nil
            }
        } else {
            systemWattsReading = nil
        }

        let componentWattsReading: MetricReading? = components?.totalWatts.map { total in
            MetricReading(value: max(0, total), unit: .watts, timestamp: timestamp,
                          detail: components?.detail ?? "Component Power",
                          measurementInterval: interval)
        }

        let adapterWattsValue = smc?.dcInWatts ?? battery?.adapterPowerWatts ?? battery?.systemPowerInWatts
        let adapterWattsReading: MetricReading? = adapterWattsValue.flatMap { value in
            guard value.isFinite, value >= 0 else { return nil }
            return MetricReading(value: value, unit: .watts, timestamp: timestamp, measurementInterval: interval)
        }

        let batteryWattsValue = smc?.batteryWatts ?? battery?.batteryPowerWatts ?? {
            guard let voltageMV = battery?.voltageMillivolts,
                  let ampsMA = battery?.instantAmperageMilliamps,
                  voltageMV > 0 else { return nil }
            return (Double(voltageMV) * Double(ampsMA)) / 1_000_000.0
        }()
        let batteryWattsReading: MetricReading? = batteryWattsValue.flatMap { rawValue in
            guard rawValue.isFinite else { return nil }
            let normalized: Double
            if resolvedCharging == true {
                normalized = abs(rawValue)
            } else if resolvedSource == .battery || (battery?.instantAmperageMilliamps ?? 0) < 0 {
                normalized = -abs(rawValue)
            } else {
                normalized = rawValue
            }
            return MetricReading(value: normalized, unit: .watts, timestamp: timestamp, measurementInterval: interval)
        }

        func componentReading(_ watts: Double?) -> MetricReading? {
            guard let watts, watts.isFinite, watts >= 0 else { return nil }
            return MetricReading(value: watts, unit: .watts, timestamp: timestamp, measurementInterval: interval)
        }

        return SystemPowerSnapshot(
            systemPowerWatts: systemWattsReading,
            componentPowerWatts: componentWattsReading,
            adapterPowerWatts: adapterWattsReading,
            batteryPowerWatts: batteryWattsReading,
            cpuPowerWatts: componentReading(components?.cpuWatts),
            gpuPowerWatts: componentReading(components?.gpuWatts),
            anePowerWatts: componentReading(components?.aneWatts),
            dramPowerWatts: componentReading(components?.dramWatts),
            powerSource: resolvedSource,
            batteryPercent: resolvedBatteryPercent,
            batteryCharging: resolvedCharging,
            batteryTimeRemainingMinutes: resolvedTimeRemaining,
            adapterMaxWatts: battery?.adapterMaxWatts,
            thermalState: thermalState
        )
    }

    static func readSmartBattery() -> SmartBatteryTelemetry? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else { return nil }

        let telemetryDict = properties["PowerTelemetryData"] as? [String: Any]
        let adapterDict = properties["AdapterDetails"] as? [String: Any]

        let currentCapacity = (properties["CurrentCapacity"] as? NSNumber)?.doubleValue
        let maxCapacity = (properties["MaxCapacity"] as? NSNumber)?.doubleValue
        let batteryPercent: Double?
        if let currentCapacity, let maxCapacity, maxCapacity > 0 {
            batteryPercent = min(100, max(0, (currentCapacity / maxCapacity) * 100.0))
        } else {
            batteryPercent = nil
        }

        let rawTime = (properties["TimeRemaining"] as? NSNumber)?.intValue
        let timeRemainingMinutes = rawTime.flatMap { $0 > 0 && $0 < 60_000 ? $0 : nil }

        return SmartBatteryTelemetry(
            systemLoadWatts: milliwatts(telemetryDict?["SystemLoad"]),
            systemPowerInWatts: milliwatts(telemetryDict?["SystemPowerIn"]),
            adapterPowerWatts: milliwatts(telemetryDict?["AdapterPower"]),
            batteryPowerWatts: milliwatts(telemetryDict?["BatteryPower"]),
            externalConnected: properties["ExternalConnected"] as? Bool,
            isCharging: properties["IsCharging"] as? Bool,
            batteryPercent: batteryPercent,
            timeRemainingMinutes: timeRemainingMinutes,
            voltageMillivolts: (properties["Voltage"] as? NSNumber)?.int64Value,
            instantAmperageMilliamps: (properties["InstantAmperage"] as? NSNumber)?.int64Value,
            adapterMaxWatts: (adapterDict?["Watts"] as? NSNumber)?.intValue
        )
    }

    static func readPowerSourceInfo() -> PowerSourceInfoSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        var internalSource: PowerSourceKind = .unknown
        var fallbackSource: PowerSourceKind = .unknown
        var sawInternalBattery = false
        var percent: Double?
        var charging: Bool?
        var timeMinutes: Int?

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let type = description[kIOPSTypeKey as String] as? String
            let sourceState = description[kIOPSPowerSourceStateKey as String] as? String
            let isInternal = type == kIOPSInternalBatteryType
            let isUPS = type == kIOPSUPSType
            let parsedSource: PowerSourceKind
            switch sourceState {
            case kIOPSACPowerValue:
                parsedSource = .ac
            case kIOPSBatteryPowerValue:
                parsedSource = isUPS ? .ups : .battery
            case kIOPSOffLineValue:
                parsedSource = .ups
            default:
                parsedSource = isUPS ? .ups : .unknown
            }
            if isInternal {
                if parsedSource != .unknown { internalSource = parsedSource }
            } else if parsedSource != .unknown, fallbackSource == .unknown || isUPS {
                fallbackSource = parsedSource
            }

            if isInternal || (!sawInternalBattery && description[kIOPSMaxCapacityKey as String] != nil && (isUPS || type == nil)) {
                if isInternal { sawInternalBattery = true }
                if let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue,
                   let maxCap = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue,
                   maxCap > 0 {
                    percent = min(100, max(0, (current / maxCap) * 100.0))
                }
                if let isCharging = description[kIOPSIsChargingKey as String] as? Bool {
                    charging = isCharging
                }
                let tte = (description[kIOPSTimeToEmptyKey as String] as? NSNumber)?.intValue
                let ttf = (description[kIOPSTimeToFullChargeKey as String] as? NSNumber)?.intValue
                if let tte, tte > 0 && tte < 60_000 {
                    timeMinutes = tte
                } else if let ttf, ttf > 0 && ttf < 60_000 {
                    timeMinutes = ttf
                }
            }
        }

        let detectedSource = internalSource != .unknown ? internalSource : fallbackSource
        return PowerSourceInfoSnapshot(powerSource: detectedSource, batteryPercent: percent,
                                       isCharging: charging, timeRemainingMinutes: timeMinutes)
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        guard let raw = (value as? NSNumber)?.doubleValue, raw.isFinite else { return nil }
        return raw / 1_000.0
    }
}
