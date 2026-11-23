import CoreFoundation
import Foundation

// Schemas are intentionally narrow; absent or invalid measurements stay unavailable.
enum AdvancedMetricsParser {
    static let maximumBytes = 4 * 1024 * 1024
    struct Power {
        let watts: Double?
        let gpuPercent: Double?
        let cpuWatts: Double?
        let gpuWatts: Double?
        let aneWatts: Double?
        let dramWatts: Double?

        init(watts: Double?,
             gpuPercent: Double?,
             cpuWatts: Double? = nil,
             gpuWatts: Double? = nil,
             aneWatts: Double? = nil,
             dramWatts: Double? = nil) {
            self.watts = watts
            self.gpuPercent = gpuPercent
            self.cpuWatts = cpuWatts
            self.gpuWatts = gpuWatts
            self.aneWatts = aneWatts
            self.dramWatts = dramWatts
        }
    }
    /// Parses GPU activity and system power from one powermetrics plist record.
    /// Power keys are milliwatts: `processor.combined_power` when present, otherwise all of
    /// `processor.cpu_power`, `processor.gpu_power` and `processor.ane_power`. A present but
    /// invalid `combined_power` yields nil rather than falling back to the components.
    static func power(_ data: Data) -> Power {
        let empty = Power(watts: nil, gpuPercent: nil)
        guard data.count <= maximumBytes else { return empty }
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        guard let last = records.last,
              let object = try? PropertyListSerialization.propertyList(from: Data(last), options: [], format: nil),
              let root = object as? [String: Any] else { return empty }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let result = value.doubleValue
            return result.isFinite && result >= 0 ? result : nil
        }
        let gpu = root["gpu"] as? [String: Any]
        let ratio = number(gpu?["idle_ratio"])
        let percent = ratio.flatMap { $0 <= 1 ? (1 - $0) * 100 : nil }
        let processor = root["processor"] as? [String: Any] ?? [:]
        let cpuW = number(processor["cpu_power"]).map { $0 / 1_000 }
        let gpuW = number(processor["gpu_power"]).map { $0 / 1_000 }
        let aneW = number(processor["ane_power"]).map { $0 / 1_000 }
        let dramW = number(processor["dram_power"]).map { $0 / 1_000 }
        var watts: Double?
        if processor["combined_power"] != nil {
            watts = number(processor["combined_power"]).map { $0 / 1_000 }
        } else if let cpuW, let gpuW, let aneW, (cpuW + gpuW + aneW).isFinite {
            watts = cpuW + gpuW + aneW
        } else if processor["package_watts"] != nil {
            watts = number(processor["package_watts"])
        }
        return Power(watts: watts, gpuPercent: percent,
                     cpuWatts: cpuW, gpuWatts: gpuW, aneWatts: aneW, dramWatts: dramW)
    }
}
