import AppKit
import Darwin
import Foundation

@MainActor
enum UIFormat {
    private static var ownerNameCache: [UInt32: String] = [:]

    /// Full metric text, including the inline "partial · detail" suffix for partial readings.
    /// Table cells should use `value(_:)` with `MetricCellPresentation` instead.
    static func metric(_ reading: MetricReading) -> String {
        guard let formatted = value(reading) else {
            return unavailable(reading.unavailableReason, detail: reading.detail)
        }
        guard reading.isPartial else { return formatted }
        let detail = reading.detail.flatMap { $0.isEmpty ? nil : $0 }
        return [formatted, "partial", detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// The number and unit only (no partial suffix, no reason). Nil when the reading has no finite value.
    static func value(_ reading: MetricReading) -> String? {
        guard let value = reading.value, value.isFinite else { return nil }
        switch reading.unit {
        case .percent:
            return percent(value)
        case .bytes:
            return ByteCountFormatter.string(fromByteCount: boundedInt64(value), countStyle: .memory)
        case .bytesPerSecond:
            return bytesPerSecond(value)
        case .count:
            return String(format: "%.0f", locale: .current, value)
        case .seconds:
            return String(format: "%.1f s", locale: .current, value)
        case .watts:
            return String(format: "%.3g W", locale: .current, value)
        case .joules:
            return String(format: "%.3g J", locale: .current, value)
        case .wattHours:
            return String(format: "%.3g Wh", locale: .current, value)
        }
    }

    /// Locale-correct percentage for a value on the 0...100 scale (`42.5` becomes "42.5%").
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return percentFormatter.string(from: NSNumber(value: value / 100)) ?? "\(value)%"
    }

    /// Throughput in decimal units (KB = 1000 bytes), matching Activity Monitor.
    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        let count = ByteCountFormatter.string(fromByteCount: boundedInt64(value), countStyle: .decimal)
        return "\(count)/s"
    }

    static func unavailable(_ reason: MetricUnavailableReason?, detail: String? = nil) -> String {
        let text: String
        switch reason {
        case .warmingUp: text = "Warming up"
        case .permissionDenied: text = "Permission denied"
        case .unsupported: text = "Unsupported"
        case .collectionFailed: text = "Collection failed"
        case .processExited: text = "Process exited"
        case .identityChanged: text = "Identity changed"
        case .counterReset: text = "Counter reset"
        case .sleepGap: text = "Sample gap"
        case .notCollected: text = "Not collected"
        case nil: text = "Unavailable"
        }
        guard let detail, !detail.isEmpty else { return text }
        return "\(text) · \(detail)"
    }

    static func availability(_ value: MetricAvailability?) -> String {
        guard let value else { return "Unavailable · capability not reported" }
        guard !value.available else { return "Available" }
        return unavailable(value.reason, detail: value.detail)
    }

    static func time(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    static func identityStart(_ startTime: ProcessStartTime) -> String {
        let seconds = TimeInterval(startTime.secondsSinceEpoch)
        let micros = TimeInterval(startTime.microseconds) / 1_000_000
        return Self.identityFormatter.string(from: Date(timeIntervalSince1970: seconds + micros))
    }

    static func ownerName(_ uid: UInt32?) -> String {
        guard let uid else { return "Unavailable" }
        if let cached = ownerNameCache[uid] { return cached }
        let name = uid == getuid() ? NSUserName() : (PasswordDatabase.name(for: uid) ?? "UID \(uid)")
        ownerNameCache[uid] = name
        return name
    }

    private static func boundedInt64(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int64.max) else { return Int64.max }
        return Int64(rounded)
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.locale = .current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let identityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
