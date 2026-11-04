import AppKit
import Darwin
import Foundation

enum UIFormat {
    static func metric(_ reading: MetricReading) -> String {
        guard let value = reading.value, value.isFinite else {
            return unavailable(reading.unavailableReason, detail: reading.detail)
        }
        switch reading.unit {
        case .percent:
            return String(format: "%.1f%%", locale: .current, value)
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

    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        let count = ByteCountFormatter.string(fromByteCount: boundedInt64(value), countStyle: .memory)
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
        if uid == getuid() { return NSUserName() }
        guard let entry = getpwuid(uid_t(uid)) else { return "UID \(uid)" }
        return String(cString: entry.pointee.pw_name)
    }

    private static func boundedInt64(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        let rounded = value.rounded()
        guard rounded < Double(Int64.max) else { return Int64.max }
        return Int64(rounded)
    }

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
