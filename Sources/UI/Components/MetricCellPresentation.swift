import Foundation

/// How one numeric table cell looks: the number, a trailing badge, and the explanation.
///
/// The explanation never goes into `valueText`. Partial readings show the number with a warning
/// badge and put the detail in `toolTip` and `accessibilityDescription`. Unavailable readings show
/// "—" with the reason in the tooltip. An unavailable value is never shown as zero.
@MainActor
struct MetricCellPresentation: Equatable {
    /// Trailing indicator for a cell.
    enum Badge: Equatable {
        /// Complete measurement; no badge.
        case none
        /// Value covers only some contributors (`MetricReading.isPartial`).
        case partial
        /// No value; the reason is in the tooltip.
        case unavailable

        /// SF Symbol name for the badge, or nil for `.none`.
        var symbolName: String? {
            switch self {
            case .none: nil
            case .partial: "exclamationmark.triangle"
            case .unavailable: "questionmark.circle"
            }
        }
    }

    /// Text for the cell: the formatted number with unit, or "—" when unavailable.
    let valueText: String
    let badge: Badge
    /// Explanation for hover help, or nil when there is nothing to add.
    let toolTip: String?
    /// Full spoken description for VoiceOver, including partial and unavailable detail.
    let accessibilityDescription: String
    /// True when `valueText` carries a measured number.
    var isAvailable: Bool { badge != .unavailable }

    /// Presents a metric reading. Partial and unavailable states come from the reading itself.
    init(_ reading: MetricReading) {
        guard let number = UIFormat.value(reading) else {
            self = Self.unavailable(reason: reading.unavailableReason, detail: reading.detail)
            return
        }
        let detail = reading.detail.flatMap { $0.isEmpty ? nil : $0 }
        if reading.isPartial {
            valueText = number
            badge = .partial
            toolTip = "Partial value. \(detail ?? "Some contributors were not collected.")"
            accessibilityDescription = [number, "partial", detail].compactMap { $0 }.joined(separator: ", ")
        } else {
            valueText = number
            badge = .none
            toolTip = detail
            accessibilityDescription = number
        }
    }

    /// Explicit presentation for composite cells (for example a read/write pair). Callers own the wording.
    init(valueText: String, badge: Badge, toolTip: String?, accessibilityDescription: String) {
        self.valueText = valueText
        self.badge = badge
        self.toolTip = toolTip
        self.accessibilityDescription = accessibilityDescription
    }

    /// Presentation for a cell with no reading, using the reason (and optional detail) explaining why.
    static func unavailable(reason: MetricUnavailableReason?, detail: String? = nil) -> MetricCellPresentation {
        let reasonText = UIFormat.unavailable(reason, detail: detail)
        return MetricCellPresentation(
            valueText: "—",
            badge: .unavailable,
            toolTip: reasonText,
            accessibilityDescription: reasonText.hasPrefix("Unavailable") ? reasonText : "Unavailable, \(reasonText)"
        )
    }

    /// Presentation for a capability that is not available (`available == false`): "—" with its reason in the tooltip.
    static func unavailable(_ availability: MetricAvailability) -> MetricCellPresentation {
        unavailable(reason: availability.reason, detail: availability.detail)
    }
}
