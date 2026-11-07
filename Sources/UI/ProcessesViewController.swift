import AppKit

/// Processes page: applications and their processes in an `NSOutlineView`, a selection bar under the
/// table, and toolbar items for search, quit, force quit and grouping.
///
/// Each snapshot builds the desired layout with `ProcessRowModel`. The controller mirrors what the
/// outline shows (`topLevelIDs`, `shownChildren`) and applies only the insert, remove and move steps
/// that differ. Cells whose content changed are reloaded in place and row views are reused.
@MainActor
final class ProcessesViewController: NSViewController, SnapshotUpdating, PageToolbarProviding,
                                     NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSSearchFieldDelegate, NSMenuDelegate, NSUserInterfaceValidations {
    private enum ToolbarItemID {
        static let search = NSToolbarItem.Identifier("process.toolbar.search")
        static let quit = NSToolbarItem.Identifier("process.toolbar.quit")
        static let forceQuit = NSToolbarItem.Identifier("process.toolbar.force-quit")
        static let grouping = NSToolbarItem.Identifier("process.toolbar.grouping")
    }

    private static let columnVisibilityKey = "process.columns.visibility"
    private static let autosaveName = "process.outline"
    private static let systemProtectedMessage = "System processes are protected and can't be quit from Microgravity."

    private let dependencies: PageDependencies
    private let outlineView = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let selectionBar = ProcessSelectionBar()

    private let searchItem = NSSearchToolbarItem(itemIdentifier: ToolbarItemID.search)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let forceQuitButton = NSButton(title: "Force Quit…", target: nil, action: nil)
    private let quitItem = NSToolbarItem(itemIdentifier: ToolbarItemID.quit)
    private let forceQuitItem = NSToolbarItem(itemIdentifier: ToolbarItemID.forceQuit)
    private let groupingItem = NSMenuToolbarItem(itemIdentifier: ToolbarItemID.grouping)
    private let groupingMenu = NSMenu()
    private let rowMenu = NSMenu()
    private let columnMenu = NSMenu()

    private var currentSnapshot: MonitoringSnapshot?
    private var processByIdentity: [ProcessIdentity: ProcessSnapshot] = [:]
    private var groupByIdentity: [ProcessIdentity: ProcessGroupSnapshot] = [:]
    private var items: [ProcessRowID: ProcessRowItem] = [:]
    /// Top-level rows as the outline view currently shows them.
    private var topLevelIDs: [ProcessRowID] = []
    /// Member rows of each group the outline view currently shows expanded.
    private var shownChildren: [ProcessRowID: [ProcessRowID]] = [:]
    private var rowsByID: [ProcessRowID: ProcessRow] = [:]
    /// Expanded groups, keyed by the group's identity. In memory only: identities do not survive a relaunch.
    private var expandedGroups = Set<ProcessIdentity>()
    private var collapsedDuringSearch = Set<ProcessIdentity>()
    private var selectedID: ProcessRowID?
    private var sort = ProcessSortState(column: .cpu, ascending: false)
    private var grouping: ProcessGrouping = .byApp
    /// Explicit column visibility choices from the header menu. Columns without a choice follow capability.
    private var columnOverrides: [String: Bool]
    /// True while the controller changes the outline itself, so delegate callbacks are not user actions.
    private var isApplyingModel = false

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        columnOverrides = UserDefaults.standard.dictionary(forKey: ProcessesViewController.columnVisibilityKey)
            as? [String: Bool] ?? [:]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Processes",
            subtitle: "Live applications and background tasks grouped by their parent or app bundle."
        )
        let headerRow = NSStackView(views: [header, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        configureOutline()
        configureToolbarItems()

        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        outlineScroll.borderType = .noBorder
        outlineScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        selectionBar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [headerRow, outlineScroll, selectionBar])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(16, after: headerRow)
        view.addSubview(content)
        NSLayoutConstraint.activate(PageLayout.pin(content, in: view) + [
            headerRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            outlineScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            outlineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            selectionBar.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        updateSelectionDetails()
    }

    // MARK: - Configuration

    private func configureOutline() {
        outlineView.setAccessibilityIdentifier("process.table")
        outlineView.setAccessibilityLabel("Processes")
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .inset
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.gridStyleMask = []
        outlineView.selectionHighlightStyle = .regular
        outlineView.indentationPerLevel = 16

        for column in ProcessColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = Self.defaultWidth(for: column)
            tableColumn.minWidth = Self.minimumWidth(for: column)
            tableColumn.headerCell.alignment = column == .name || column == .user ? .left : .right
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableColumn.headerCell.setAccessibilityIdentifier(column.rawValue)
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        // Autosave after the columns exist so saved widths and order apply to them.
        outlineView.autosaveName = Self.autosaveName
        outlineView.autosaveTableColumns = true
        outlineView.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]
        applyColumnVisibility()

        rowMenu.delegate = self
        rowMenu.autoenablesItems = true
        outlineView.menu = rowMenu
        columnMenu.delegate = self
        outlineView.headerView?.menu = columnMenu
    }

    private static func defaultWidth(for column: ProcessColumn) -> CGFloat {
        switch column {
        case .name: return 200
        case .pid: return 60
        case .user: return 100
        case .cpu: return 80
        case .memory: return 100
        case .disk: return 190
        case .network: return 130
        case .gpu: return 100
        }
    }

    private static func minimumWidth(for column: ProcessColumn) -> CGFloat {
        switch column {
        case .name: return 160
        case .pid: return 52
        case .user: return 72
        case .cpu: return 64
        case .memory: return 84
        case .disk: return 140
        case .network: return 104
        case .gpu: return 84
        }
    }

    private func configureToolbarItems() {
        searchItem.label = "Search"
        searchItem.paletteLabel = "Search Processes"
        searchItem.toolTip = "Search by name, path, PID or user (⌘F)"
        searchItem.preferredWidthForSearchField = 220
        searchItem.searchField.placeholderString = "Search processes"
        searchItem.searchField.setAccessibilityIdentifier("process.search")
        searchItem.searchField.setAccessibilityLabel("Search processes")
        searchItem.searchField.delegate = self
        (searchItem.searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true

        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitSelectedProcess(_:))
        quitButton.setAccessibilityIdentifier("process.action.quit")
        quitButton.isEnabled = false
        quitItem.label = "Quit"
        quitItem.paletteLabel = "Quit Process"
        quitItem.toolTip = "Quit the selected process (⌘⌥Q)"
        quitItem.view = quitButton

        forceQuitButton.bezelStyle = .rounded
        forceQuitButton.target = self
        forceQuitButton.action = #selector(forceQuitSelectedProcess(_:))
        forceQuitButton.setAccessibilityIdentifier("process.action.force-quit")
        forceQuitButton.isEnabled = false
        forceQuitItem.label = "Force Quit…"
        forceQuitItem.paletteLabel = "Force Quit Process"
        forceQuitItem.toolTip = "Force quit the selected process (⌘⌥⇧Q)"
        forceQuitItem.view = forceQuitButton

        let byApp = NSMenuItem(title: "Group by App", action: #selector(setProcessGrouping(_:)), keyEquivalent: "")
        byApp.tag = 0
        byApp.target = self
        let flat = NSMenuItem(title: "Flat List", action: #selector(setProcessGrouping(_:)), keyEquivalent: "")
        flat.tag = 1
        flat.target = self
        groupingMenu.addItem(byApp)
        groupingMenu.addItem(flat)
        groupingMenu.autoenablesItems = false
        groupingItem.label = "Grouping"
        groupingItem.paletteLabel = "Grouping"
        groupingItem.toolTip = "Group processes by app, or list them flat"
        groupingItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Grouping")
        groupingItem.menu = groupingMenu
        groupingItem.showsIndicator = true
        updateGroupingMenu()
    }

    // MARK: - Page toolbar

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [ToolbarItemID.search, ToolbarItemID.quit, ToolbarItemID.forceQuit, ToolbarItemID.grouping]
    }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case ToolbarItemID.search: return searchItem
        case ToolbarItemID.quit: return quitItem
        case ToolbarItemID.forceQuit: return forceQuitItem
        case ToolbarItemID.grouping: return groupingItem
        default: return nil
        }
    }

    // MARK: - Snapshot

    func update(snapshot: MonitoringSnapshot) {
        currentSnapshot = snapshot
        processByIdentity = Dictionary(snapshot.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupByIdentity = Dictionary(snapshot.processGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        applyColumnVisibility()
        applyModel()
    }

    private func makeInput() -> ProcessOutlineInput {
        ProcessOutlineInput(
            processes: currentSnapshot?.processes ?? [],
            groups: currentSnapshot?.processGroups ?? [],
            capabilities: currentSnapshot?.capabilities ?? [:],
            timestamp: currentSnapshot?.timestamp ?? Date(),
            physicalMemoryBytes: currentSnapshot?.system.memoryTotalBytes.value,
            query: searchQuery,
            grouping: grouping,
            sort: sort,
            expandedGroups: expandedGroups,
            collapsedDuringSearch: collapsedDuringSearch,
            ownerName: { UIFormat.ownerName($0) }
        )
    }

    private var searchQuery: String {
        searchItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuilds the desired layout and applies the difference to the outline view.
    private func applyModel() {
        let previousRows = rowsByID
        let output = ProcessRowModel.build(makeInput())
        register(output)

        isApplyingModel = true
        defer { isApplyingModel = false }

        // Collapse groups the new layout no longer expands, so their member rows leave first.
        for id in Array(shownChildren.keys) where output.children[id] == nil {
            if let item = items[id], outlineView.row(forItem: item) >= 0 {
                animated { outlineView.collapseItem(item) }
            }
            shownChildren[id] = nil
        }

        let topOperations = ProcessRowModel.operations(from: topLevelIDs, to: output.topLevel)
        var childOperations: [(parent: ProcessRowID, operations: [ProcessRowDiffOperation<ProcessRowID>])] = []
        for id in output.topLevel {
            guard let shown = shownChildren[id], let wanted = output.children[id] else { continue }
            let operations = ProcessRowModel.operations(from: shown, to: wanted)
            if !operations.isEmpty { childOperations.append((id, operations)) }
        }
        outlineView.beginUpdates()
        for operation in topOperations {
            perform(operation, parent: nil)
        }
        for (parent, operations) in childOperations {
            for operation in operations {
                perform(operation, parent: parent)
            }
        }
        outlineView.endUpdates()

        // Groups that are newly expanded: their members are inserted after the group row exists.
        for id in output.topLevel where shownChildren[id] == nil {
            guard let wanted = output.children[id], let item = items[id] else { continue }
            shownChildren[id] = wanted
            animated { outlineView.expandItem(item) }
        }

        reloadChangedCells(previous: previousRows, next: output)
        rowsByID = output.rows
        items = items.filter { output.rows[$0.key] != nil }
        syncSelection(visible: visibleRowIDs)
        updateSelectionDetails()
    }

    private var visibleRowIDs: [ProcessRowID] {
        topLevelIDs.flatMap { [$0] + (shownChildren[$0] ?? []) }
    }

    /// Applies one diff step to the outline and to the mirror, which must change together.
    private func perform(_ operation: ProcessRowDiffOperation<ProcessRowID>, parent: ProcessRowID?) {
        let parentItem: Any? = parent.flatMap { items[$0] }
        let options = animationOptions
        switch operation {
        case .remove(let index):
            mutateChildren(of: parent) { children in _ = children.remove(at: index) }
            outlineView.removeItems(at: IndexSet(integer: index), inParent: parentItem, withAnimation: options)
        case .insert(let id, let index):
            mutateChildren(of: parent) { children in children.insert(id, at: index) }
            outlineView.insertItems(at: IndexSet(integer: index), inParent: parentItem, withAnimation: options)
        case .move(let from, let to):
            mutateChildren(of: parent) { children in
                let moved = children.remove(at: from)
                children.insert(moved, at: to)
            }
            outlineView.moveItem(at: from, inParent: parentItem, to: to, inParent: parentItem)
        }
    }

    private func mutateChildren(of parent: ProcessRowID?, _ change: (inout [ProcessRowID]) -> Void) {
        guard let parent else {
            change(&topLevelIDs)
            return
        }
        var children = shownChildren[parent] ?? []
        change(&children)
        shownChildren[parent] = children
    }

    private var animationOptions: NSTableView.AnimationOptions {
        MotionPolicy.prefersReducedMotion ? [] : .effectFade
    }

    private func animated(_ changes: () -> Void) {
        MotionPolicy.animate(changes)
    }

    private func register(_ output: ProcessOutline) {
        for (id, row) in output.rows {
            item(for: id).row = row
        }
    }

    private func item(for id: ProcessRowID) -> ProcessRowItem {
        if let existing = items[id] { return existing }
        let created = ProcessRowItem(id: id)
        items[id] = created
        return created
    }

    /// Reloads only the cells whose content changed. Rows are located through the outline view itself,
    /// so this is correct whether or not a pending expansion has finished.
    private func reloadChangedCells(previous: [ProcessRowID: ProcessRow], next: ProcessOutline) {
        var rowIndexes = IndexSet()
        var columnIndexes = IndexSet()
        for id in next.visibleOrder {
            guard let old = previous[id], let new = next.rows[id], let item = items[id] else { continue }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { continue }
            if old.accessibilityID != new.accessibilityID, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
                rowView.setAccessibilityIdentifier(new.accessibilityID)
                if let processRowView = rowView as? ProcessRowView {
                    processRowView.configureDisclosure(toggleID: new.toggleID, expanded: outlineView.isItemExpanded(item),
                                                       target: self, action: #selector(toggleGroupRow(_:)))
                }
            }
            let changed = ProcessColumn.allCases.filter { old.cells[$0] != new.cells[$0] }
            guard !changed.isEmpty else { continue }
            rowIndexes.insert(row)
            for column in changed {
                columnIndexes.insert(outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)))
            }
        }
        if !rowIndexes.isEmpty {
            outlineView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }
    }

    /// Keeps the selection on the same row identity. A row that is no longer visible clears it.
    private func syncSelection(visible: [ProcessRowID]) {
        if let selectedID, processByIdentity[selectedID.identity] == nil {
            self.selectedID = nil
        }
        selectedID = ProcessRowModel.selection(after: selectedID, visible: visible)
        if let selectedID, let index = visible.firstIndex(of: selectedID) {
            if outlineView.selectedRow != index {
                outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        } else if outlineView.selectedRow != -1 {
            outlineView.deselectAll(nil)
        }
    }

    // MARK: - Columns

    /// A column is hidden when the user hid it; otherwise GPU and Network hide when their capability is unavailable.
    private func columnHidden(_ column: ProcessColumn) -> Bool {
        if let override = columnOverrides[column.suffix] { return !override }
        guard let snapshot = currentSnapshot else { return false }
        switch column {
        case .network: return snapshot.capabilities[.processNetwork]?.available != true
        case .gpu: return snapshot.capabilities[.processGPUTime]?.available != true
        default: return false
        }
    }

    private func applyColumnVisibility() {
        for column in ProcessColumn.allCases where column.isHideable {
            guard let tableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) else { continue }
            tableColumn.isHidden = columnHidden(column)
        }
    }

    private func rebuildColumnMenu() {
        columnMenu.removeAllItems()
        for column in ProcessColumn.allCases where column.isHideable {
            let item = NSMenuItem(title: column.title, action: #selector(toggleProcessColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = columnHidden(column) ? .off : .on
            columnMenu.addItem(item)
        }
    }

    @objc private func toggleProcessColumn(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let column = ProcessColumn(rawValue: key) else { return }
        columnOverrides[column.suffix] = columnHidden(column)
        UserDefaults.standard.set(columnOverrides, forKey: Self.columnVisibilityKey)
        applyColumnVisibility()
    }

    // MARK: - Selection details

    private var selectedProcess: ProcessSnapshot? {
        selectedID.flatMap { processByIdentity[$0.identity] }
    }

    private var selectedPath: String? {
        guard let selectedID else { return nil }
        return rowsByID[selectedID]?.executablePath ?? selectedProcess?.executablePath
    }

    private var hasValidSelection: Bool { selectedProcess != nil }

    private func updateSelectionDetails() {
        guard let selectedID, let process = processByIdentity[selectedID.identity] else {
            selectionBar.showEmpty()
            setActionsEnabled(false)
            return
        }
        let row = rowsByID[selectedID]
        let title = row?.title ?? process.name
        let path = row?.executablePath ?? process.executablePath
        let owner = UIFormat.ownerName(process.ownerUID)
        let start = String(UIFormat.identityStart(process.id.startTime).prefix(19))
        let icon = row?.isGroup == true
            ? AppIconProvider.icon(forBundlePath: row?.iconBundlePath)
            : AppIconProvider.genericExecutableIcon()
        selectionBar.show(
            title: title,
            summary: "PID \(process.id.pid) · \(owner) · \(path ?? "Path unavailable")",
            identity: "pid=\(process.id.pid) · started \(start)",
            icon: icon
        )
        setActionsEnabled(true)
    }

    private func setActionsEnabled(_ enabled: Bool) {
        quitButton.isEnabled = enabled
        forceQuitButton.isEnabled = enabled
        quitItem.isEnabled = enabled
        forceQuitItem.isEnabled = enabled
    }

    private func clearSelection() {
        selectedID = nil
        outlineView.deselectAll(nil)
        updateSelectionDetails()
    }

    // MARK: - Outline data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? ProcessRowItem else { return topLevelIDs.count }
        return shownChildren[item.id]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let siblings = (item as? ProcessRowItem).map { shownChildren[$0.id] ?? [] } ?? topLevelIDs
        guard siblings.indices.contains(index) else { return NSNull() }
        return self.item(for: siblings[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProcessRowItem)?.row?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ProcessRowItem, let row = item.row, let tableColumn,
              let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue),
              let content = row.cells[column] else { return nil }
        switch content {
        case .name(let name):
            let cell = outlineView.makeView(withIdentifier: ProcessNameCellView.reuseIdentifier, owner: self)
                as? ProcessNameCellView ?? ProcessNameCellView(frame: .zero)
            cell.configure(name)
            return cell
        case .text(let text):
            let identifier = NSUserInterfaceItemIdentifier("process.cell.\(column.suffix)")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ProcessTextCellView
                ?? makeTextCell(identifier: identifier)
            cell.configure(text: text, alignment: column == .pid ? .right : .left,
                           monospacedDigits: column == .pid,
                           valueIdentifier: "\(row.accessibilityID).\(column.suffix)",
                           cellIdentifier: "\(row.accessibilityID).cell.\(column.suffix)")
            return cell
        case .metric(let presentation, let heat):
            let identifier = NSUserInterfaceItemIdentifier("process.cell.\(column.suffix)")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MetricValueCellView
                ?? makeMetricCell(identifier: identifier)
            cell.configure(presentation: presentation, heatIntensity: heat, alignment: .right,
                           accessibilityIdentifier: "\(row.accessibilityID).\(column.suffix)")
            cell.setAccessibilityIdentifier("\(row.accessibilityID).cell.\(column.suffix)")
            return cell
        }
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> ProcessTextCellView {
        let cell = ProcessTextCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func makeMetricCell(identifier: NSUserInterfaceItemIdentifier) -> MetricValueCellView {
        let cell = MetricValueCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = outlineView.makeView(withIdentifier: ProcessRowView.reuseIdentifier, owner: self)
            as? ProcessRowView ?? ProcessRowView(frame: .zero)
        let rowItem = item as? ProcessRowItem
        rowView.item = rowItem
        rowView.setAccessibilityIdentifier(rowItem?.row?.accessibilityID)
        let expanded = outlineView.isItemExpanded(item)
        rowView.configureDisclosure(toggleID: rowItem?.row?.toggleID, expanded: expanded,
                                    target: self, action: #selector(toggleGroupRow(_:)))
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel else { return }
        let row = outlineView.selectedRow
        if row >= 0, let item = outlineView.item(atRow: row) as? ProcessRowItem {
            selectedID = item.id
        } else {
            selectedID = nil
        }
        updateSelectionDetails()
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !isApplyingModel, let item = notificationItem(notification),
              case .group(let identity) = item.id else { return }
        expandedGroups.insert(identity)
        collapsedDuringSearch.remove(identity)
        // The outline asks for the child count right after this callback, so the mirror must be ready now.
        let output = ProcessRowModel.build(makeInput())
        register(output)
        shownChildren[item.id] = output.children[item.id] ?? []
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplyingModel, let item = notificationItem(notification) else { return }
        setDisclosureState(for: item, expanded: true)
        refreshAfterUserToggle()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingModel, let item = notificationItem(notification),
              case .group(let identity) = item.id else { return }
        expandedGroups.remove(identity)
        if !searchQuery.isEmpty { collapsedDuringSearch.insert(identity) }
        shownChildren[item.id] = nil
        setDisclosureState(for: item, expanded: false)
        refreshAfterUserToggle()
    }

    private func notificationItem(_ notification: Notification) -> ProcessRowItem? {
        notification.userInfo?["NSObject"] as? ProcessRowItem
    }

    private func setDisclosureState(for item: ProcessRowItem, expanded: Bool) {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? ProcessRowView else { return }
        rowView.setDisclosureExpanded(expanded)
    }

    /// Refreshes cells whose content depends on the visible set (heat maxima) after a user expand or collapse.
    private func refreshAfterUserToggle() {
        let previous = rowsByID
        let output = ProcessRowModel.build(makeInput())
        register(output)
        isApplyingModel = true
        defer { isApplyingModel = false }
        reloadChangedCells(previous: previous, next: output)
        rowsByID = output.rows
        syncSelection(visible: visibleRowIDs)
        updateSelectionDetails()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key, let column = ProcessColumn(rawValue: key) else { return }
        sort = ProcessSortState(column: column, ascending: descriptor.ascending)
        applyModel()
    }

    @objc private func toggleGroupRow(_ sender: NSButton) {
        guard let item = (sender.superview as? ProcessRowView)?.item, item.row?.isExpandable == true else { return }
        animated {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ notification: Notification) {
        collapsedDuringSearch.removeAll()
        applyModel()
    }

    // MARK: - Grouping

    @objc func setProcessGrouping(_ sender: NSMenuItem) {
        grouping = sender.tag == 1 ? .flat : .byApp
        updateGroupingMenu()
        applyModel()
    }

    private func updateGroupingMenu() {
        let selectedTag = grouping == .flat ? 1 : 0
        for item in groupingMenu.items {
            item.state = item.tag == selectedTag ? .on : .off
        }
    }

    // MARK: - Actions

    @objc func quitSelectedProcess(_ sender: Any?) {
        requestTermination(force: false)
    }

    @objc func forceQuitSelectedProcess(_ sender: Any?) {
        requestTermination(force: true)
    }

    @objc func revealSelectedProcess(_ sender: Any?) {
        guard let path = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func copySelectedPath(_ sender: Any?) {
        guard let path = selectedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Switches to the Details page. Details does not yet select a process from another page.
    @objc func showSelectedProcessInDetails(_ sender: Any?) {
        guard let root = view.window?.contentViewController as? RootViewController else { return }
        root.select(.details)
    }

    /// Focuses the toolbar search field (⌘F).
    @objc func focusProcessSearch(_ sender: Any?) {
        searchItem.beginSearchInteraction()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let action = item.action
        if action == #selector(quitSelectedProcess(_:)) || action == #selector(forceQuitSelectedProcess(_:)) {
            return hasValidSelection
        }
        if action == #selector(revealSelectedProcess(_:)) || action == #selector(copySelectedPath(_:)) {
            return selectedPath != nil
        }
        return true
    }

    private func requestTermination(force: Bool) {
        guard let selectedID, let process = processByIdentity[selectedID.identity] else {
            presentNotice(title: "Process No Longer Available",
                          message: "The selected process is no longer available.")
            clearSelection()
            return
        }
        let identity = selectedID.identity
        let name = process.name
        let targetIsSystemOwned = process.ownerUID == 0
        Task { [weak self] in
            guard let self else { return }
            if force {
                let response = await SheetAlert.present(
                    on: view.window,
                    style: .warning,
                    messageText: "Confirm Force Quit",
                    informativeText: "Force quit \(name) (process \(identity.pid)) only. Its child processes are not targeted.",
                    buttons: ["Force Quit", "Cancel"],
                    defaultButtonIdentifier: "process.force-quit.confirm"
                )
                guard response == .alertFirstButtonReturn else { return }
            }
            let result = await dependencies.processActions.terminate(identity: identity, force: force)
            switch result.outcome {
            case .signalSent:
                await dependencies.monitoringStore.refreshNow()
            case .rejected(let reason, let detail):
                let isStale = reason == .processExited || reason == .identityChanged || reason == .invalidIdentity
                if isStale { clearSelection() }
                await dependencies.monitoringStore.refreshNow()
                let message = Self.rejectionMessage(reason, detail: detail, targetIsSystemOwned: targetIsSystemOwned)
                await SheetAlert.present(
                    on: view.window,
                    style: .informational,
                    messageText: isStale ? "Process No Longer Available" : "Process action not completed",
                    informativeText: message,
                    buttons: ["OK"]
                )
            }
        }
    }

    /// The text for a rejected action. Root-owned and system processes get one plain explanation: the
    /// privileged helper never signals them by design (see `HelperTerminationPolicy`).
    static func rejectionMessage(_ reason: ProcessActionRejection, detail: String?, targetIsSystemOwned: Bool) -> String {
        if targetIsSystemOwned, reason == .differentUser || reason == .protectedProcess {
            return systemProtectedMessage
        }
        let base: String
        switch reason {
        case .invalidIdentity, .identityChanged, .processExited: base = "The selected process changed or exited. No process was terminated."
        case .currentProcess: base = "Microgravity cannot terminate itself."
        case .pidOne: base = "The system’s launch process is protected."
        case .protectedProcess: base = "This process is protected."
        case .differentUser: base = "This process belongs to another user."
        case .permissionDenied: base = "Permission was denied."
        case .helperUnavailable: base = "The required helper is unavailable."
        case .signalFailed: base = "The operating system could not send the signal."
        }
        if let detail, !detail.isEmpty { return "\(base) \(detail)" }
        return base
    }

    private func presentNotice(title: String, message: String) {
        Task { [weak self] in
            guard let self else { return }
            await SheetAlert.present(on: view.window, style: .informational, messageText: title,
                                     informativeText: message, buttons: ["OK"])
        }
    }

    // MARK: - Context and column menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === columnMenu {
            rebuildColumnMenu()
            return
        }
        guard menu === rowMenu else { return }
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, outlineView.item(atRow: row) is ProcessRowItem else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        menu.addItem(contextItem("Quit Process", #selector(quitSelectedProcess(_:))))
        menu.addItem(contextItem("Force Quit…", #selector(forceQuitSelectedProcess(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("Reveal in Finder", #selector(revealSelectedProcess(_:))))
        menu.addItem(contextItem("Copy Path", #selector(copySelectedPath(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("Show in Details", #selector(showSelectedProcessInDetails(_:))))
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
