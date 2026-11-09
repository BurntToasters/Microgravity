import AppKit

/// Identity of one outline row. A group's leader is also one of its members, so the row kind is part
/// of the key: `.group(410)` and `.process(410)` are different rows.
enum ProcessRowID: Hashable {
    case group(ProcessIdentity)
    case process(ProcessIdentity)

    var identity: ProcessIdentity {
        switch self {
        case .group(let identity), .process(let identity): return identity
        }
    }
}

/// `byApp` nests member processes under their group; `flat` lists every process at the top level.
enum ProcessGrouping: Equatable {
    case byApp
    case flat
}

/// Stores only full PID-plus-start-time identities. A reused PID cannot inherit an old expansion.
enum ProcessGroupExpansionPersistence {
    static let defaultsKey = "process.expandedGroups.v1"
    private static let maximumCount = 16_384
    private static let maximumEncodedBytes = 4 * 1024 * 1024

    static func load(from defaults: UserDefaults) -> Set<ProcessIdentity> {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= maximumEncodedBytes,
              let decoded = try? JSONDecoder().decode([ProcessIdentity].self, from: data) else {
            defaults.removeObject(forKey: defaultsKey)
            return []
        }
        return Set(decoded.lazy.filter(isValid).prefix(maximumCount))
    }

    static func save(_ identities: Set<ProcessIdentity>, to defaults: UserDefaults) {
        let ordered = identities.filter(isValid).sorted(by: orderedBefore).prefix(maximumCount)
        guard !ordered.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(Array(ordered)), data.count <= maximumEncodedBytes else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    static func available(_ identities: Set<ProcessIdentity>, in groups: [ProcessGroupSnapshot]) -> Set<ProcessIdentity> {
        let current = Set(groups.map(\.id))
        return identities.intersection(current)
    }

    private static func isValid(_ identity: ProcessIdentity) -> Bool {
        identity.pid > 0
            && identity.startTime.secondsSinceEpoch >= 0
            && (0..<1_000_000).contains(identity.startTime.microseconds)
    }

    private static func orderedBefore(_ lhs: ProcessIdentity, _ rhs: ProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.startTime < rhs.startTime
    }
}

/// Process table columns in display order. The raw value is the column identifier and the sort key.
enum ProcessColumn: String, CaseIterable {
    case name = "process.column.name"
    case pid = "process.column.pid"
    case user = "process.column.user"
    case cpu = "process.column.cpu"
    case memory = "process.column.memory"
    case disk = "process.column.disk"
    case network = "process.column.network"
    case gpu = "process.column.gpu"

    /// Stem used in row accessibility identifiers, for example `cpu` in `process.row.410.cpu`.
    var suffix: String { String(rawValue.dropFirst("process.column.".count)) }

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .pid: return String(localized: "PID")
        case .user: return String(localized: "User")
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "Memory")
        case .disk: return String(localized: "Disk R / W")
        case .network: return String(localized: "Network")
        case .gpu: return String(localized: "GPU")
        }
    }

    /// Name always stays visible; every other column can be hidden from the header menu.
    var isHideable: Bool { self != .name }

    /// Hue of the heat fill in this column's metric cells. CPU, Memory, Disk and Network follow the user's metric
    /// colors; the other columns keep the warning orange.
    @MainActor var heatColor: NSColor {
        switch self {
        case .cpu: return ColorPreferences.color(for: .cpu)
        case .memory: return ColorPreferences.color(for: .memory)
        case .disk: return ColorPreferences.color(for: .disk)
        case .network: return ColorPreferences.color(for: .network)
        case .name, .pid, .user, .gpu: return .systemOrange
        }
    }
}

struct ProcessSortState: Equatable {
    var column: ProcessColumn
    var ascending: Bool
}

/// Name-column content. Equal content means the cell does not need to be reloaded.
struct ProcessNameContent: Equatable {
    let title: String
    let isGroup: Bool
    /// Application bundle whose icon represents the group; nil shows the generic executable icon.
    let bundlePath: String?
    let accessibilityID: String
}

/// Content of one cell. Metric cells carry the presentation and the heat fraction (0...1, nil for none).
@MainActor
enum ProcessCellContent: Equatable {
    case name(ProcessNameContent)
    case text(String)
    case metric(MetricCellPresentation, heat: Double?)
}

/// One outline row with everything the view needs. Pure value data; no views.
@MainActor
struct ProcessRow: Equatable {
    let id: ProcessRowID
    let title: String
    let isGroup: Bool
    let isExpandable: Bool
    let accessibilityID: String
    /// Accessibility identifier of the group's disclosure target; nil for process rows.
    let toggleID: String?
    let executablePath: String?
    let iconBundlePath: String?
    let cells: [ProcessColumn: ProcessCellContent]

    var identity: ProcessIdentity { id.identity }
}

/// Everything `ProcessRowModel.build` needs from the latest snapshot and the controls.
@MainActor
struct ProcessOutlineInput {
    var processes: [ProcessSnapshot]
    var groups: [ProcessGroupSnapshot]
    var capabilities: [MetricKind: MetricAvailability]
    var timestamp: Date
    var physicalMemoryBytes: Double?
    var query: String
    var grouping: ProcessGrouping
    var sort: ProcessSortState
    /// Groups the user expanded, keyed by the group's identity.
    var expandedGroups: Set<ProcessIdentity>
    /// Groups the user collapsed while a search was active; they stay collapsed until the search changes.
    var collapsedDuringSearch: Set<ProcessIdentity>
    var ownerName: (UInt32?) -> String
}

/// The desired outline layout. `children` lists the members of expanded groups only.
@MainActor
struct ProcessOutline {
    var topLevel: [ProcessRowID]
    var children: [ProcessRowID: [ProcessRowID]]
    var rows: [ProcessRowID: ProcessRow]

    /// Row order when every group in `children` is expanded.
    var visibleOrder: [ProcessRowID] {
        topLevel.flatMap { [$0] + (children[$0] ?? []) }
    }
}

/// One step of a sequence that turns one list of row IDs into another. Indexes refer to the list
/// as it is when the step runs. `move` removes at `from`, then inserts at `to`.
enum ProcessRowDiffOperation<ID: Hashable>: Equatable {
    case remove(index: Int)
    case insert(ID, index: Int)
    case move(from: Int, to: Int)
}

/// Reference-type outline item. NSOutlineView keys items by object identity, so one instance per row ID.
@MainActor
final class ProcessRowItem: NSObject {
    let id: ProcessRowID
    var row: ProcessRow?

    init(id: ProcessRowID) {
        self.id = id
    }
}

/// Pure row building, sorting, search and diffing for the Processes outline. No AppKit views.
@MainActor
enum ProcessRowModel {
    /// Builds the desired layout from the snapshot and the page controls.
    static func build(_ input: ProcessOutlineInput) -> ProcessOutline {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = Context(input: input, query: query)
        if input.grouping == .flat {
            let raws = input.processes.filter(context.processMatches).map(context.rawProcess)
            let top = sorted(raws, by: input.sort)
            let rows = makeRows(top.map { ($0, false) }, context: context)
            return ProcessOutline(topLevel: top.map(\.id), children: [:], rows: rows)
        }

        var entries: [Entry] = []
        for group in input.groups {
            let members = group.members.compactMap { context.byIdentity[$0] }
            let groupMatches = context.searching && context.groupMatches(group)
            let visibleMembers = context.searching && !groupMatches ? members.filter(context.processMatches) : members
            if context.searching && !groupMatches && visibleMembers.isEmpty { continue }
            let isExpandable = !visibleMembers.isEmpty
            let manual = input.expandedGroups.contains(group.id)
            let automatic = context.searching && isExpandable && !input.collapsedDuringSearch.contains(group.id)
            let expanded = isExpandable && (manual || automatic)
            entries.append(Entry(raw: context.rawGroup(group, members: members),
                                 isExpandable: isExpandable,
                                 expanded: expanded,
                                 children: sorted(visibleMembers.map(context.rawProcess), by: input.sort)))
        }
        entries = entries.sorted { lhs, rhs in
            precedes(lhs.raw, rhs.raw, by: input.sort)
        }

        var displayed: [(RawRow, Bool)] = entries.map { ($0.raw, $0.isExpandable) }
        for entry in entries where entry.expanded {
            displayed += entry.children.map { ($0, false) }
        }
        let rows = makeRows(displayed, context: context)
        var children: [ProcessRowID: [ProcessRowID]] = [:]
        for entry in entries where entry.expanded && !entry.children.isEmpty {
            children[entry.raw.id] = entry.children.map(\.id)
        }
        return ProcessOutline(topLevel: entries.map(\.raw.id), children: children, rows: rows)
    }

    /// Operations that turn `old` into `new`. Both lists must hold unique IDs.
    static func operations<ID: Hashable>(from old: [ID], to new: [ID]) -> [ProcessRowDiffOperation<ID>] {
        boundedOperations(from: old, to: new, limit: Int.max) ?? []
    }

    /// Like `operations(from:to:)`, but returns nil as soon as more than `limit` steps are needed. Callers that
    /// would rather reload a level than apply a long diff stop paying for the diff at that point.
    static func boundedOperations<ID: Hashable>(from old: [ID], to new: [ID],
                                                limit: Int) -> [ProcessRowDiffOperation<ID>]? {
        var operations: [ProcessRowDiffOperation<ID>] = []
        var mirror = old
        let kept = Set(new)
        for index in old.indices.reversed() where !kept.contains(old[index]) {
            operations.append(.remove(index: index))
            if operations.count > limit { return nil }
            mirror.remove(at: index)
        }
        for target in new.indices {
            let id = new[target]
            if target < mirror.count, mirror[target] == id { continue }
            if target < mirror.count,
               let source = (target + 1 ..< mirror.count).first(where: { mirror[$0] == id }) {
                operations.append(.move(from: source, to: target))
                let moved = mirror.remove(at: source)
                mirror.insert(moved, at: target)
            } else {
                operations.append(.insert(id, index: target))
                mirror.insert(id, at: target)
            }
            if operations.count > limit { return nil }
        }
        return operations
    }

    /// Applies `operations` to `list`. Used to verify a diff; the controller applies the same steps to the outline.
    static func apply<ID: Hashable>(_ operations: [ProcessRowDiffOperation<ID>], to list: [ID]) -> [ID] {
        var result = list
        for operation in operations {
            switch operation {
            case .remove(let index):
                result.remove(at: index)
            case .insert(let id, let index):
                result.insert(id, at: index)
            case .move(let from, let to):
                let moved = result.remove(at: from)
                result.insert(moved, at: to)
            }
        }
        return result
    }

    /// The selection after a refresh: the previous row if it is still visible, otherwise nil.
    static func selection(after previous: ProcessRowID?, visible: [ProcessRowID]) -> ProcessRowID? {
        guard let previous, visible.contains(previous) else { return nil }
        return previous
    }

    /// The `.app` bundle containing an executable path, for example `/Applications/Notes.app`.
    static func appBundlePath(for path: String?) -> String? {
        UIText.appBundlePath(forExecutable: path)
    }

    /// Lowercase, dash-separated slug used in accessibility identifiers.
    static func slug(_ value: String) -> String {
        UIText.slug(value)
    }

    /// Heat fraction for a value against a maximum: nil when either is missing, otherwise clamped to 0...1.
    static func heat(_ value: Double?, maximum: Double?) -> Double? {
        guard let value, value.isFinite, let maximum, maximum > 0 else { return nil }
        return min(max(value / maximum, 0), 1)
    }

    /// Disk read and write as one cell: "R … · W …", with the worst badge of the two halves.
    static func diskPresentation(read: MetricCellPresentation, write: MetricCellPresentation) -> MetricCellPresentation {
        let badge: MetricCellPresentation.Badge
        if read.badge == .unavailable || write.badge == .unavailable {
            badge = .unavailable
        } else if read.badge == .partial || write.badge == .partial {
            badge = .partial
        } else {
            badge = .none
        }
        let tips = [read.toolTip.map { String(localized: "Read: \($0)") }, write.toolTip.map { String(localized: "Write: \($0)") }].compactMap { $0 }
        return MetricCellPresentation(
            valueText: String(localized: "R \(read.valueText) · W \(write.valueText)"),
            badge: badge,
            toolTip: tips.isEmpty ? nil : tips.joined(separator: "\n"),
            accessibilityDescription: String(localized: "Read \(read.accessibilityDescription), write \(write.accessibilityDescription)")
        )
    }

    // MARK: - Sorting

    /// Sort key. Unavailable values are `.missing`, which sorts after every value in both directions.
    @MainActor
    private enum SortValue {
        case text(String)
        case number(Double)
        case missing
    }

    @MainActor
    private struct RawRow {
        let id: ProcessRowID
        let title: String
        let isGroup: Bool
        let accessibilityID: String
        let toggleID: String?
        let executablePath: String?
        let iconBundlePath: String?
        let ownerUID: UInt32?
        let ownerName: String
        let pid: Int32
        let cpu: MetricReading
        let memory: MetricReading
        let diskRead: MetricReading
        let diskWrite: MetricReading
        let network: MetricReading
        let gpu: MetricReading
    }

    @MainActor
    private struct Entry {
        let raw: RawRow
        let isExpandable: Bool
        let expanded: Bool
        let children: [RawRow]
    }

    private static func sorted(_ raws: [RawRow], by sort: ProcessSortState) -> [RawRow] {
        raws.sorted { precedes($0, $1, by: sort) }
    }

    private static func precedes(_ lhs: RawRow, _ rhs: RawRow, by sort: ProcessSortState) -> Bool {
        let left = sortValue(lhs, sort.column)
        let right = sortValue(rhs, sort.column)
        if isOrderedBefore(left, right, ascending: sort.ascending) { return true }
        if isOrderedBefore(right, left, ascending: sort.ascending) { return false }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.id.identity.startTime < rhs.id.identity.startTime
    }

    private static func isOrderedBefore(_ lhs: SortValue, _ rhs: SortValue, ascending: Bool) -> Bool {
        switch (lhs, rhs) {
        case (.missing, _):
            return false
        case (_, .missing):
            return true
        case let (.number(left), .number(right)):
            return ascending ? left < right : left > right
        case let (.text(left), .text(right)):
            let order = left.localizedStandardCompare(right)
            if order == .orderedSame { return false }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        default:
            return false
        }
    }

    private static func sortValue(_ raw: RawRow, _ column: ProcessColumn) -> SortValue {
        switch column {
        case .name: return .text(raw.title)
        case .pid: return .number(Double(raw.pid))
        case .user: return raw.ownerUID == nil ? .missing : .text(raw.ownerName)
        case .cpu: return numeric(raw.cpu.value)
        case .memory: return numeric(raw.memory.value)
        case .disk: return numeric(diskTotal(read: raw.diskRead, write: raw.diskWrite))
        case .network: return numeric(raw.network.value)
        case .gpu: return numeric(raw.gpu.value)
        }
    }

    private static func numeric(_ value: Double?) -> SortValue {
        guard let value, value.isFinite else { return .missing }
        return .number(value)
    }

    static func diskTotal(read: MetricReading, write: MetricReading) -> Double? {
        guard let readValue = read.value, readValue.isFinite,
              let writeValue = write.value, writeValue.isFinite else { return nil }
        let total = readValue + writeValue
        return total.isFinite ? total : nil
    }

    // MARK: - Rows

    private static func makeRows(_ displayed: [(RawRow, Bool)], context: Context) -> [ProcessRowID: ProcessRow] {
        var maxDisk: Double?
        var maxNetwork: Double?
        for (raw, _) in displayed {
            if let total = diskTotal(read: raw.diskRead, write: raw.diskWrite), total > (maxDisk ?? -.infinity) {
                maxDisk = total
            }
            if let value = raw.network.value, value.isFinite, value > (maxNetwork ?? -.infinity) {
                maxNetwork = value
            }
        }
        var rows: [ProcessRowID: ProcessRow] = [:]
        for (raw, isExpandable) in displayed {
            rows[raw.id] = makeRow(raw, isExpandable: isExpandable, maxDisk: maxDisk,
                                   maxNetwork: maxNetwork, physicalMemory: context.input.physicalMemoryBytes)
        }
        return rows
    }

    private static func makeRow(_ raw: RawRow, isExpandable: Bool, maxDisk: Double?, maxNetwork: Double?,
                                physicalMemory: Double?) -> ProcessRow {
        let disk = diskTotal(read: raw.diskRead, write: raw.diskWrite)
        var cells: [ProcessColumn: ProcessCellContent] = [:]
        cells[.name] = .name(ProcessNameContent(title: raw.title, isGroup: raw.isGroup,
                                                bundlePath: raw.iconBundlePath,
                                                accessibilityID: raw.accessibilityID))
        cells[.pid] = .text(String(raw.pid))
        cells[.user] = .text(raw.ownerName)
        cells[.cpu] = .metric(MetricCellPresentation(raw.cpu), heat: heat(raw.cpu.value, maximum: 100))
        cells[.memory] = .metric(MetricCellPresentation(raw.memory),
                                 heat: heat(raw.memory.value, maximum: physicalMemory))
        cells[.disk] = .metric(diskPresentation(read: MetricCellPresentation(raw.diskRead),
                                                write: MetricCellPresentation(raw.diskWrite)),
                               heat: heat(disk, maximum: maxDisk))
        cells[.network] = .metric(MetricCellPresentation(raw.network), heat: heat(raw.network.value, maximum: maxNetwork))
        cells[.gpu] = .metric(MetricCellPresentation(raw.gpu), heat: nil)
        return ProcessRow(id: raw.id, title: raw.title, isGroup: raw.isGroup, isExpandable: isExpandable,
                          accessibilityID: raw.accessibilityID, toggleID: raw.toggleID,
                          executablePath: raw.executablePath, iconBundlePath: raw.iconBundlePath, cells: cells)
    }

    private static func groupIdentifierSuffix(_ identity: ProcessIdentity) -> String {
        "pid-\(identity.pid)-start-\(identity.startTime.secondsSinceEpoch)-\(identity.startTime.microseconds)"
    }

    private static func contains(_ text: String?, _ query: String) -> Bool {
        text?.localizedStandardContains(query) ?? false
    }

    /// Per-build state: lookups and the search query.
    @MainActor
    private struct Context {
        let input: ProcessOutlineInput
        let query: String
        let searching: Bool
        let byIdentity: [ProcessIdentity: ProcessSnapshot]
        let slugCounts: [String: Int]
        let timestamp: Date

        init(input: ProcessOutlineInput, query: String) {
            self.input = input
            self.query = query
            searching = !query.isEmpty
            timestamp = input.timestamp
            var byIdentity: [ProcessIdentity: ProcessSnapshot] = [:]
            for process in input.processes where byIdentity[process.id] == nil {
                byIdentity[process.id] = process
            }
            self.byIdentity = byIdentity
            var counts: [String: Int] = [:]
            for group in input.groups { counts[ProcessRowModel.slug(group.title), default: 0] += 1 }
            slugCounts = counts
        }

        func processMatches(_ process: ProcessSnapshot) -> Bool {
            guard searching else { return true }
            return ProcessRowModel.contains(process.name, query)
                || ProcessRowModel.contains(process.executablePath, query)
                || ProcessRowModel.contains(String(process.id.pid), query)
                || (process.ownerUID.map { ProcessRowModel.contains(input.ownerName($0), query) } ?? false)
        }

        func groupMatches(_ group: ProcessGroupSnapshot) -> Bool {
            guard searching else { return true }
            return ProcessRowModel.contains(group.title, query)
                || ProcessRowModel.contains(group.executablePath, query)
                || ProcessRowModel.contains(String(group.id.pid), query)
                || (group.ownerUID.map { ProcessRowModel.contains(input.ownerName($0), query) } ?? false)
        }

        func missingReading(_ kind: MetricKind) -> MetricReading {
            let capability = input.capabilities[kind]
            let unavailable = capability?.available == false
            return MetricReading(
                unavailable: ProcessRowModel.advancedUnit(kind), timestamp: timestamp,
                reason: unavailable ? (capability?.reason ?? .notCollected) : .notCollected,
                detail: unavailable ? capability?.detail : nil)
        }

        func processReading(_ process: ProcessSnapshot, _ kind: MetricKind) -> MetricReading {
            process.advancedMetrics[kind] ?? missingReading(kind)
        }

        func groupReading(_ group: ProcessGroupSnapshot, _ kind: MetricKind) -> MetricReading {
            guard !group.members.isEmpty else { return missingReading(kind) }
            let readings = group.members.map { identity in
                byIdentity[identity].map { processReading($0, kind) } ?? missingReading(kind)
            }
            return SystemMonitorCollector.combineRates(readings, unit: ProcessRowModel.advancedUnit(kind),
                                                       timestamp: timestamp)
        }

        func owner(_ uid: UInt32?) -> String {
            input.ownerName(uid)
        }

        func rawProcess(_ process: ProcessSnapshot) -> RawRow {
            RawRow(
                id: .process(process.id), title: process.name, isGroup: false,
                accessibilityID: "process.row.\(process.id.pid)", toggleID: nil,
                executablePath: process.executablePath, iconBundlePath: nil,
                ownerUID: process.ownerUID, ownerName: owner(process.ownerUID), pid: process.id.pid,
                cpu: process.cpuPercent, memory: process.memoryBytes,
                diskRead: process.diskReadBytesPerSecond, diskWrite: process.diskWriteBytesPerSecond,
                network: processReading(process, .processNetwork),
                gpu: processReading(process, .processGPUTime))
        }

        func rawGroup(_ group: ProcessGroupSnapshot, members: [ProcessSnapshot]) -> RawRow {
            let duplicated = (slugCounts[ProcessRowModel.slug(group.title)] ?? 0) > 1
            let slug = ProcessRowModel.slug(group.title)
            let suffix = duplicated ? ".\(groupIdentifierSuffix(group.id))" : ""
            return RawRow(
                id: .group(group.id), title: group.title, isGroup: true,
                accessibilityID: "process.group.\(slug)\(suffix)",
                toggleID: "process.group.toggle.\(slug)\(suffix)",
                executablePath: group.executablePath,
                iconBundlePath: group.association == .applicationBundle
                    ? ProcessRowModel.appBundlePath(for: group.executablePath) : nil,
                ownerUID: group.ownerUID, ownerName: owner(group.ownerUID), pid: group.id.pid,
                cpu: group.cpuPercent, memory: group.memoryBytes,
                diskRead: group.diskReadBytesPerSecond, diskWrite: group.diskWriteBytesPerSecond,
                network: groupReading(group, .processNetwork),
                gpu: groupReading(group, .processGPUTime))
        }
    }

    fileprivate static func advancedUnit(_ kind: MetricKind) -> MetricUnit {
        kind == .processNetwork ? .bytesPerSecond : .seconds
    }
}
