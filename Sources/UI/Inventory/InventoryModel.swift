import AppKit

/// Columns of the Startup and Services tables. Raw values are the column keys (also the header identifiers).
enum InventoryColumn: String, CaseIterable {
    case name
    case kind
    case state
    case owner
    case path

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .kind: return String(localized: "Kind")
        case .state: return String(localized: "Status")
        case .owner: return String(localized: "Owner")
        case .path: return String(localized: "Known path")
        }
    }

    var width: CGFloat {
        switch self {
        case .name: return 210
        case .kind: return 130
        case .state: return 120
        case .owner: return 110
        case .path: return 320
        }
    }
}

/// Colour meaning of a status dot. Mapped to system colours by the table.
enum InventoryStatusTone: Equatable {
    /// Running or loaded (green).
    case positive
    /// Stopped (orange).
    case caution
    /// Not reported (grey).
    case neutral
}

/// Human labels for discovered entries.
enum InventoryLabels {
    static func kind(_ kind: DiscoveredEntryKind) -> String {
        switch kind {
        case .loginItem: return String(localized: "Login Item")
        case .launchAgent: return String(localized: "Launch Agent")
        case .launchDaemon: return String(localized: "Launch Daemon")
        case .service: return String(localized: "Service")
        }
    }

    static func status(_ state: DiscoveredEntryState) -> (label: String, tone: InventoryStatusTone) {
        switch state {
        case .running: return (String(localized: "Running"), .positive)
        case .loaded: return (String(localized: "Loaded"), .positive)
        case .stopped: return (String(localized: "Stopped"), .caution)
        case .unknown: return (String(localized: "Unknown"), .neutral)
        }
    }
}

/// One table row, built from a discovered entry.
struct InventoryRow: Equatable {
    /// `<page>.item.<slug>`, with `.entry.<id>` appended when slugs collide.
    let id: String
    let entry: DiscoveredEntrySnapshot
    let kind: String
    let status: String
    let tone: InventoryStatusTone
    let owner: String

    var name: String { entry.name }
    var path: String? { entry.path }

    /// Display text for a column (path falls back to a plain "Path unavailable").
    func text(_ column: InventoryColumn) -> String {
        switch column {
        case .name: return entry.name
        case .kind: return kind
        case .state: return status
        case .owner: return owner
        case .path: return entry.path ?? String(localized: "Path unavailable")
        }
    }

    /// Bundle path for the row icon: the last `.app` component of the path, or nil (generic executable icon).
    var iconBundlePath: String? {
        guard let path = entry.path, let range = path.range(of: ".app", options: .backwards) else { return nil }
        guard range.upperBound == path.endIndex || path[range.upperBound] == "/" else { return nil }
        return String(path[..<range.upperBound])
    }
}

@MainActor
enum InventoryRows {
    /// Rows for a page, sorted by name. Duplicate slugs get an entry-ID suffix so row identifiers stay unique.
    static func rows(for entries: [DiscoveredEntrySnapshot], pageIdentifier: String) -> [InventoryRow] {
        let slugCounts = Dictionary(grouping: entries, by: { slug($0.id) }).mapValues(\.count)
        return entries
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { entry -> InventoryRow in
                let entrySlug = slug(entry.id)
                let suffix = (slugCounts[entrySlug] ?? 0) > 1 ? ".entry.\(entry.id)" : ""
                let status = InventoryLabels.status(entry.state)
                return InventoryRow(
                    id: "\(pageIdentifier).item.\(entrySlug)\(suffix)",
                    entry: entry,
                    kind: InventoryLabels.kind(entry.kind),
                    status: status.label,
                    tone: status.tone,
                    owner: UIFormat.ownerName(entry.ownerUID)
                )
            }
    }

    /// Stable sort by one column's display text (case-insensitive natural order). Ties keep input order.
    static func ordered(_ rows: [InventoryRow], by column: InventoryColumn?, ascending: Bool) -> [InventoryRow] {
        guard let column else { return rows }
        return rows.enumerated().sorted { left, right in
            let comparison = left.element.text(column).localizedStandardCompare(right.element.text(column))
            if comparison == .orderedSame { return left.offset < right.offset }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    static func slug(_ value: String) -> String {
        UIText.slug(value)
    }
}
