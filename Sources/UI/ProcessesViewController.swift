import AppKit

@MainActor
final class ProcessesViewController: NSViewController, SnapshotUpdating,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    NSSearchFieldDelegate, NSMenuDelegate {
    private enum Row {
        case group(ProcessGroupSnapshot)
        case process(ProcessSnapshot)

        var identity: ProcessIdentity {
            switch self {
            case .group(let group): return group.id
            case .process(let process): return process.id
            }
        }

    }

    private enum SortField: String {
        case name = "process.column.name"
        case pid = "process.column.pid"
        case user = "process.column.user"
        case cpu = "process.column.cpu"
        case memory = "process.column.memory"
        case disk = "process.column.disk"
        case network = "process.column.network"
        case gpu = "process.column.gpu"
    }

    private let dependencies: PageDependencies
    private let searchField = NSSearchField()
    private var tableView = NSTableView()
    private let selectionIdentity = NSTextField(labelWithString: "No process selected")
    private let selectionSummary = NSTextField(labelWithString: "Select a row to inspect its identity.")
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let forceQuitButton = NSButton(title: "Force Quit…", target: nil, action: nil)
    private let freshnessLabel = NSTextField(labelWithString: "Waiting for the first sample")
    private var currentSnapshot: MonitoringSnapshot?
    private var processByIdentity: [ProcessIdentity: ProcessSnapshot] = [:]
    private var groups: [ProcessGroupSnapshot] = []
    private var groupSlugCounts: [String: Int] = [:]
    private var visibleRows: [Row] = []
    private var expandedGroups = Set<ProcessIdentity>()
    private var selectedIdentity: ProcessIdentity?
    private var sortField: SortField = .cpu
    private var sortAscending = false

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Processes",
            subtitle: "Live applications and background tasks grouped by their parent or app bundle."
        )
        let headerRow = NSStackView(views: [header, NSView(), freshnessLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        freshnessLabel.font = .systemFont(ofSize: 11)
        freshnessLabel.textColor = .secondaryLabelColor
        freshnessLabel.setAccessibilityIdentifier("process.freshness")

        searchField.placeholderString = "Search processes"
        searchField.setAccessibilityIdentifier("process.search")
        searchField.delegate = self
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .lineBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        selectionIdentity.font = .systemFont(ofSize: 12, weight: .semibold)
        selectionIdentity.setAccessibilityIdentifier("process.selection.identity")
        selectionSummary.font = .systemFont(ofSize: 11)
        selectionSummary.textColor = .secondaryLabelColor

        quitButton.target = self
        quitButton.action = #selector(quitSelectedProcess)
        quitButton.setAccessibilityIdentifier("process.action.quit")
        quitButton.isEnabled = false
        forceQuitButton.target = self
        forceQuitButton.action = #selector(forceQuitSelectedProcess)
        forceQuitButton.setAccessibilityIdentifier("process.action.force-quit")
        forceQuitButton.isEnabled = false

        let actionStack = NSStackView(views: [quitButton, forceQuitButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        let note = UIComponents.label("Actions target the selected process only.", size: 11, color: .secondaryLabelColor)
        let selectionStack = NSStackView(views: [selectionIdentity, selectionSummary, actionStack, note])
        selectionStack.orientation = .vertical
        selectionStack.alignment = .leading
        selectionStack.spacing = 5
        selectionStack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [headerRow, searchField, tableScroll, selectionStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(16, after: headerRow)
        content.setCustomSpacing(3, after: searchField)
        content.setCustomSpacing(12, after: tableScroll)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            tableScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            headerRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            selectionStack.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        currentSnapshot = snapshot
        processByIdentity = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.id, $0) })
        groups = sortedGroups(snapshot.processGroups)
        groupSlugCounts = Dictionary(grouping: groups, by: { slug($0.title) }).mapValues(\.count)
        freshnessLabel.stringValue = dependencies.monitoringStore.isPaused
            ? "Paused · last sample \(UIFormat.time(snapshot.timestamp))"
            : "Updated \(UIFormat.time(snapshot.timestamp))"
        rebuildRows(preservingSelection: true)
    }

    private func configureTable() {
        tableView.setAccessibilityIdentifier("process.table")
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.gridStyleMask = []
        tableView.gridColor = .separatorColor
        tableView.selectionHighlightStyle = .regular

        let definitions: [(String, String, CGFloat)] = [
            ("name", "Name", 290),
            ("pid", "PID", 72),
            ("user", "User", 110),
            ("cpu", "CPU", 92),
            ("memory", "Memory", 110),
            ("disk", "Disk R / W", 160),
            ("network", "Network", 140),
            ("gpu", "GPU", 110)
        ]
        for (key, title, width) in definitions {
            let identifier = NSUserInterfaceItemIdentifier("process.column.\(key)")
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = key == "name" ? 180 : 68
            column.headerCell.alignment = key == "name" || key == "user" ? .left : .right
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true)
            column.headerCell.setAccessibilityIdentifier(identifier.rawValue)
            tableView.addTableColumn(column)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: SortField.cpu.rawValue, ascending: false)]
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        tableView.menu = menu
    }

    private func rebuildRows(preservingSelection: Bool) {
        let oldSelection = preservingSelection ? selectedIdentity : nil
        visibleRows.removeAll(keepingCapacity: true)
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for group in groups {
            let members = group.members.compactMap { processByIdentity[$0] }
            let matches = query.isEmpty
                || group.title.lowercased().contains(query)
                || members.contains { $0.name.lowercased().contains(query) || String($0.id.pid).contains(query) }
            guard matches else { continue }
            visibleRows.append(.group(group))
            if expandedGroups.contains(group.id) || !query.isEmpty {
                let filteredMembers = members.filter { process in
                    query.isEmpty || group.title.lowercased().contains(query)
                        || process.name.lowercased().contains(query)
                        || String(process.id.pid).contains(query)
                }
                for process in sortedProcesses(filteredMembers) {
                    visibleRows.append(.process(process))
                }
            }
        }
        tableView.reloadData()
        if let oldSelection, let rowIndex = visibleRows.firstIndex(where: { $0.identity == oldSelection }) {
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            selectedIdentity = oldSelection
            updateSelectionDetails()
        } else {
            selectedIdentity = nil
            tableView.deselectAll(nil)
            updateSelectionDetails()
        }
    }

    private func sortedGroups(_ input: [ProcessGroupSnapshot]) -> [ProcessGroupSnapshot] {
        input.sorted { left, right in
            let order: ComparisonResult
            switch sortField {
            case .name:
                order = left.title.localizedStandardCompare(right.title)
            case .pid:
                order = left.id.pid == right.id.pid ? .orderedSame : (left.id.pid < right.id.pid ? .orderedAscending : .orderedDescending)
            case .user:
                order = UIFormat.ownerName(left.ownerUID).localizedStandardCompare(UIFormat.ownerName(right.ownerUID))
            case .cpu:
                order = compare(left.cpuPercent.value, right.cpuPercent.value)
            case .memory:
                order = compare(left.memoryBytes.value, right.memoryBytes.value)
            case .disk:
                let leftValue = groupDiskTotal(for: left)
                let rightValue = groupDiskTotal(for: right)
                order = compare(leftValue, rightValue)
            case .network:
                order = compare(groupAdvancedValue(left, kind: .processNetwork), groupAdvancedValue(right, kind: .processNetwork))
            case .gpu:
                order = compare(groupAdvancedValue(left, kind: .processGPUTime), groupAdvancedValue(right, kind: .processGPUTime))
            }
            if order == .orderedSame { return left.id.pid < right.id.pid }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func sortedProcesses(_ input: [ProcessSnapshot]) -> [ProcessSnapshot] {
        input.sorted { left, right in
            let order: ComparisonResult
            switch sortField {
            case .name:
                order = left.name.localizedStandardCompare(right.name)
            case .pid:
                order = left.id.pid == right.id.pid ? .orderedSame : (left.id.pid < right.id.pid ? .orderedAscending : .orderedDescending)
            case .user:
                order = UIFormat.ownerName(left.ownerUID).localizedStandardCompare(UIFormat.ownerName(right.ownerUID))
            case .cpu:
                order = compare(left.cpuPercent.value, right.cpuPercent.value)
            case .memory:
                order = compare(left.memoryBytes.value, right.memoryBytes.value)
            case .disk:
                order = compare((left.diskReadBytesPerSecond.value ?? 0) + (left.diskWriteBytesPerSecond.value ?? 0),
                                (right.diskReadBytesPerSecond.value ?? 0) + (right.diskWriteBytesPerSecond.value ?? 0))
            case .network:
                order = compare(left.advancedMetrics[.processNetwork]?.value, right.advancedMetrics[.processNetwork]?.value)
            case .gpu:
                order = compare(left.advancedMetrics[.processGPUTime]?.value, right.advancedMetrics[.processGPUTime]?.value)
            }
            if order == .orderedSame { return left.id.pid < right.id.pid }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func groupAdvancedValue(_ group: ProcessGroupSnapshot, kind: MetricKind) -> Double? {
        let readings = group.members.compactMap { processByIdentity[$0]?.advancedMetrics[kind]?.value }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +)
    }

    private func advancedDescription(_ kind: MetricKind, value: Double?) -> String {
        let unit: MetricUnit = kind == .processNetwork ? .bytesPerSecond : .seconds
        let timestamp = currentSnapshot?.timestamp ?? Date()
        if let value { return UIFormat.metric(MetricReading(value: value, unit: unit, timestamp: timestamp)) }
        let capability = currentSnapshot?.capabilities[kind]
        return UIFormat.unavailable(capability?.reason ?? .notCollected, detail: capability?.detail)
    }

    private func groupDiskTotal(for group: ProcessGroupSnapshot) -> Double? {
        guard let read = group.diskReadBytesPerSecond.value,
              let write = group.diskWriteBytesPerSecond.value else { return nil }
        return read + write
    }

    private func compare(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (left?, right?):
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleRows.indices.contains(row), let tableColumn else { return nil }
        let item = visibleRows[row]
        let key = tableColumn.identifier.rawValue
        let itemID = accessibilityID(for: item)
        if key == SortField.name.rawValue {
            let reuseIdentifier = ProcessNameCellView.reuseIdentifier
            let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self) as? ProcessNameCellView
                ?? ProcessNameCellView(frame: .zero)
            cell.identifier = reuseIdentifier
            cell.setAccessibilityIdentifier(itemID + ".cell.name")
            switch item {
            case .group(let group):
                cell.configure(text: group.title, accessibilityID: itemID, group: true,
                               expanded: expandedGroups.contains(group.id),
                               toggleIdentifier: toggleAccessibilityID(for: group),
                               groupIdentity: group.id, target: self, action: #selector(toggleGroup(_:)))
            case .process(let process):
                cell.configure(text: process.name, accessibilityID: itemID, group: false, expanded: false,
                               toggleIdentifier: nil, groupIdentity: nil, target: nil, action: nil)
            }
            return cell
        }

        let reuseIdentifier = NSUserInterfaceItemIdentifier("process.cell.\(key)")
        let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self) as? ProcessValueCellView
            ?? ProcessValueCellView(frame: .zero)
        cell.identifier = reuseIdentifier
        cell.configure(
            value: value(for: item, column: key),
            rowAccessibilityID: itemID,
            column: key,
            alignment: key == SortField.user.rawValue ? .left : .right,
            backgroundColor: heatmapColor(for: item, column: key)
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        if visibleRows.indices.contains(row) {
            view.setAccessibilityIdentifier(accessibilityID(for: visibleRows[row]))
        }
        return view
    }

    private func value(for row: Row, column: String) -> String {
        switch row {
        case .group(let group):
            switch column {
            case SortField.pid.rawValue: return String(group.id.pid)
            case SortField.user.rawValue: return UIFormat.ownerName(group.ownerUID)
            case SortField.cpu.rawValue: return UIFormat.metric(group.cpuPercent)
            case SortField.memory.rawValue: return UIFormat.metric(group.memoryBytes)
            case SortField.disk.rawValue: return groupDiskDescription(group)
            case SortField.network.rawValue: return advancedDescription(.processNetwork, value: groupAdvancedValue(group, kind: .processNetwork))
            case SortField.gpu.rawValue: return advancedDescription(.processGPUTime, value: groupAdvancedValue(group, kind: .processGPUTime))
            default: return ""
            }
        case .process(let process):
            switch column {
            case SortField.pid.rawValue: return String(process.id.pid)
            case SortField.user.rawValue: return UIFormat.ownerName(process.ownerUID)
            case SortField.cpu.rawValue: return UIFormat.metric(process.cpuPercent)
            case SortField.memory.rawValue: return UIFormat.metric(process.memoryBytes)
            case SortField.disk.rawValue:
                return "R \(UIFormat.metric(process.diskReadBytesPerSecond)) · W \(UIFormat.metric(process.diskWriteBytesPerSecond))"
            case SortField.network.rawValue: return process.advancedMetrics[.processNetwork].map(UIFormat.metric) ?? advancedDescription(.processNetwork, value: nil)
            case SortField.gpu.rawValue: return process.advancedMetrics[.processGPUTime].map(UIFormat.metric) ?? advancedDescription(.processGPUTime, value: nil)
            default: return ""
            }
        }
    }

    private func groupDiskDescription(_ group: ProcessGroupSnapshot) -> String {
        return "R \(UIFormat.metric(group.diskReadBytesPerSecond)) · W \(UIFormat.metric(group.diskWriteBytesPerSecond))"
    }

    private func heatmapColor(for row: Row, column: String) -> NSColor {
        let value: Double?
        let maximum: Double
        switch (row, column) {
        case (.group(let group), SortField.cpu.rawValue): value = group.cpuPercent.value; maximum = 100
        case (.process(let process), SortField.cpu.rawValue): value = process.cpuPercent.value; maximum = 100
        case (.group(let group), SortField.memory.rawValue): value = group.memoryBytes.value; maximum = max(currentSnapshot?.system.memoryTotalBytes.value ?? 1, 1)
        case (.process(let process), SortField.memory.rawValue): value = process.memoryBytes.value; maximum = max(currentSnapshot?.system.memoryTotalBytes.value ?? 1, 1)
        default: return .clear
        }
        guard let value else { return .clear }
        let intensity = min(max(value / maximum, 0), 1)
        return NSColor.systemOrange.withAlphaComponent(0.025 + intensity * 0.12)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let rowIndex = tableView.selectedRow
        guard visibleRows.indices.contains(rowIndex) else {
            selectedIdentity = nil
            updateSelectionDetails()
            return
        }
        selectedIdentity = visibleRows[rowIndex].identity
        updateSelectionDetails()
    }

    private func updateSelectionDetails() {
        guard let identity = selectedIdentity else {
            selectionIdentity.stringValue = "No process selected"
            selectionSummary.stringValue = "Select a row to inspect its identity."
            quitButton.isEnabled = false
            forceQuitButton.isEnabled = false
            return
        }
        selectionIdentity.stringValue = "pid=\(identity.pid) start=\(UIFormat.identityStart(identity.startTime))"
        selectionIdentity.setAccessibilityIdentifier("process.selection.identity")
        if let process = processByIdentity[identity] {
            selectionSummary.stringValue = "\(process.name) · \(UIFormat.ownerName(process.ownerUID)) · \(process.executablePath ?? "Path unavailable")"
        } else if let group = groups.first(where: { $0.id == identity }) {
            selectionSummary.stringValue = "\(group.title) · \(UIFormat.ownerName(group.ownerUID)) · Actions target this process only."
        } else {
            selectionSummary.stringValue = "This process is no longer in the latest snapshot."
            selectedIdentity = nil
        }
        let valid = selectedIdentity.map { processByIdentity[$0] != nil } ?? false
        quitButton.isEnabled = valid
        forceQuitButton.isEnabled = valid
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let field = SortField(rawValue: descriptor.key ?? "") else { return }
        sortField = field
        sortAscending = descriptor.ascending
        groups = sortedGroups(currentSnapshot?.processGroups ?? [])
        rebuildRows(preservingSelection: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildRows(preservingSelection: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard visibleRows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let valid = selectedIdentity.map { processByIdentity[$0] != nil } ?? false
        let quit = NSMenuItem(title: "Quit Process", action: #selector(quitSelectedProcess), keyEquivalent: "")
        quit.target = self
        quit.isEnabled = valid
        menu.addItem(quit)
        let force = NSMenuItem(title: "Force Quit…", action: #selector(forceQuitSelectedProcess), keyEquivalent: "")
        force.target = self
        force.isEnabled = valid
        menu.addItem(force)
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        // Walk up to the containing cell view; `tableView.row(for:)` returns
        // -1 for buttons nested inside table cell views on current macOS.
        var view: NSView? = sender
        while let current = view {
            if let cell = current as? ProcessNameCellView, let identity = cell.groupIdentity {
                if expandedGroups.contains(identity) {
                    expandedGroups.remove(identity)
                } else {
                    expandedGroups.insert(identity)
                }
                rebuildRows(preservingSelection: true)
                return
            }
            view = current.superview
        }
        let row = tableView.row(for: sender)
        guard visibleRows.indices.contains(row), case .group(let group) = visibleRows[row] else { return }
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
        rebuildRows(preservingSelection: true)
    }

    @objc private func quitSelectedProcess() {
        requestTermination(force: false)
    }

    @objc private func forceQuitSelectedProcess() {
        requestTermination(force: true)
    }

    private func requestTermination(force: Bool) {
        guard let identity = selectedIdentity,
              let process = processByIdentity[identity] else {
            showActionError("The selected process is no longer available.")
            clearSelection()
            return
        }
        if force {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Confirm Force Quit"
            alert.informativeText = "Force quit \(process.name) (process \(identity.pid)) only. Its child processes are not targeted."
            alert.addButton(withTitle: "Force Quit")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.setAccessibilityIdentifier("process.force-quit.confirm")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await dependencies.processActions.terminate(identity: identity, force: force)
            switch result.outcome {
            case .signalSent:
                await dependencies.monitoringStore.refreshNow()
            case .rejected(let reason, let detail):
                let message = actionRejectionMessage(reason, detail: detail)
                let isStale = reason == .processExited || reason == .identityChanged || reason == .invalidIdentity
                if isStale {
                    clearSelection()
                }
                showActionError(message, title: isStale ? "Process No Longer Available" : "Process action not completed")
                await dependencies.monitoringStore.refreshNow()
            }
        }
    }

    private func actionRejectionMessage(_ reason: ProcessActionRejection, detail: String?) -> String {
        let base: String
        switch reason {
        case .invalidIdentity, .identityChanged, .processExited: base = "The selected process changed or exited. No process was terminated."
        case .currentProcess: base = "Microgravity cannot terminate itself."
        case .pidOne: base = "The system’s launch process is protected."
        case .protectedProcess: base = "This system process is protected."
        case .differentUser: base = "This process belongs to another user."
        case .permissionDenied: base = "Permission was denied."
        case .helperUnavailable: base = "The required helper is unavailable."
        case .signalFailed: base = "The operating system could not send the signal."
        }
        if let detail, !detail.isEmpty { return "\(base) \(detail)" }
        return base
    }

    private func showActionError(_ message: String, title: String = "Process action not completed") {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func clearSelection() {
        selectedIdentity = nil
        tableView.deselectAll(nil)
        updateSelectionDetails()
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    private func accessibilityID(for row: Row) -> String {
        switch row {
        case .group(let group):
            let base = "process.group.\(slug(group.title))"
            return (groupSlugCounts[slug(group.title)] ?? 0) > 1 ? "\(base).\(identitySuffix(group.id))" : base
        case .process(let process):
            return "process.row.\(process.id.pid)"
        }
    }

    private func toggleAccessibilityID(for group: ProcessGroupSnapshot) -> String {
        let base = "process.group.toggle.\(slug(group.title))"
        return (groupSlugCounts[slug(group.title)] ?? 0) > 1 ? "\(base).\(identitySuffix(group.id))" : base
    }

    private func identitySuffix(_ identity: ProcessIdentity) -> String {
        "pid-\(identity.pid)-start-\(identity.startTime.secondsSinceEpoch)-\(identity.startTime.microseconds)"
    }

}

@MainActor
private final class ProcessNameCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("process.cell.name")
    private let disclosure = ProcessDisclosureButton(title: "", target: nil, action: nil)
    private let nameField = NSTextField(labelWithString: "")
    private var nameLeadingConstraint: NSLayoutConstraint!
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.isBordered = false
        disclosure.bezelStyle = .inline
        disclosure.imagePosition = .imageOnly
        disclosure.setButtonType(.momentaryPushIn)
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand group")
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = .systemFont(ofSize: 12)
        addSubview(disclosure)
        addSubview(nameField)
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 20),
            disclosure.heightAnchor.constraint(equalToConstant: 20),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        nameLeadingConstraint = nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27)
        NSLayoutConstraint.activate([nameLeadingConstraint])
    }

    required init?(coder: NSCoder) { nil }

    private(set) var groupIdentity: ProcessIdentity?

    func configure(text: String, accessibilityID: String, group: Bool, expanded: Bool, toggleIdentifier: String?,
                   groupIdentity: ProcessIdentity?, target: AnyObject?, action: Selector?) {
        self.groupIdentity = group ? groupIdentity : nil
        nameField.stringValue = text
        nameField.font = .systemFont(ofSize: 12, weight: group ? .semibold : .regular)
        nameField.setAccessibilityIdentifier(accessibilityID + ".name")
        nameLeadingConstraint.constant = group ? 27 : 43
        disclosure.isHidden = !group
        disclosure.setAccessibilityIdentifier(toggleIdentifier)
        disclosure.identifier = NSUserInterfaceItemIdentifier(toggleIdentifier ?? "process.disclosure.hidden")
        disclosure.target = target
        disclosure.action = action
        let symbol = expanded ? "chevron.down" : "chevron.right"
        disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: expanded ? "Collapse group" : "Expand group")
        disclosure.toolTip = expanded ? "Collapse process group" : "Expand process group"
    }
}

@MainActor
private final class ProcessDisclosureButton: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        _ = sendAction(action, to: target)
        return true
    }
}

@MainActor
private final class ProcessValueCellView: NSTableCellView {
    private let valueField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueField.lineBreakMode = .byTruncatingTail
        valueField.wantsLayer = true
        valueField.layer?.cornerRadius = 4
        valueField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueField)
        NSLayoutConstraint.activate([
            valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(value: String, rowAccessibilityID: String, column: String,
                   alignment: NSTextAlignment, backgroundColor: NSColor) {
        valueField.stringValue = value
        valueField.alignment = alignment
        valueField.setAccessibilityIdentifier(rowAccessibilityID + "." + column)
        valueField.layer?.backgroundColor = backgroundColor.cgColor
        setAccessibilityIdentifier(rowAccessibilityID + ".cell." + column)
    }
}
