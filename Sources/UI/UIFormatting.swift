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
            return memoryFormatter.string(fromByteCount: boundedInt64(value))
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

    /// Byte formatters that write "0 KB" rather than ByteCountFormatter's default "Zero KB".
    private static let memoryFormatter = byteFormatter(.memory)
    private static let throughputFormatter = byteFormatter(.decimal)

    private static func byteFormatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter
    }

    /// Locale-correct percentage for a value on the 0...100 scale (`42.5` becomes "42.5%").
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return percentFormatter.string(from: NSNumber(value: value / 100)) ?? "\(value)%"
    }

    /// Throughput in decimal units (KB = 1000 bytes), matching Activity Monitor.
    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        let count = throughputFormatter.string(fromByteCount: boundedInt64(value))
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
        // The helper's internal error code means nothing to a user; say what it stands for.
        if detail == HelperSamplingClient.unavailableError {
            return "\(text) · the optional helper is not available"
        }
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
}

/// Pure text helpers shared by the UI models. Kept free of AppKit state so tests can call them directly.
enum UIText {
    /// Lowercase, dash-separated slug used in accessibility identifiers and row IDs.
    /// Runs of non-alphanumeric characters collapse to one dash, and leading or trailing dashes are dropped.
    static func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    /// The outermost `.app` bundle containing `executablePath`, for example `/Applications/Notes.app`
    /// for `/Applications/Notes.app/Contents/MacOS/Notes`. Nil when no path component is an app bundle.
    /// The suffix match is case-insensitive, and the result keeps a leading slash for absolute paths.
    static func appBundlePath(forExecutable executablePath: String?) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let joined = parts[...index].joined(separator: "/")
        return executablePath.hasPrefix("/") ? "/" + joined : joined
    }
}
