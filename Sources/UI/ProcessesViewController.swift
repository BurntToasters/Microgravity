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
    private static let systemProtectedMessage = String(localized: "System processes are protected and can't be quit from Microgravity.")
    /// Longest diff applied row by row; longer changes at one level reload that level instead.
    private static let incrementalOperationLimit = 40
    private static let startTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let dependencies: PageDependencies
    private let defaults: UserDefaults
    private let outlineAutosaveName: String?
    private let outlineView = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let selectionBar = ProcessSelectionBar()

    private let searchItem = NSSearchToolbarItem(itemIdentifier: ToolbarItemID.search)
    private let quitButton = NSButton(title: String(localized: "Quit"), target: nil, action: nil)
    private let forceQuitButton = NSButton(title: String(localized: "Force Quit…"), target: nil, action: nil)
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
    /// Expanded groups, keyed by the full group identity and restored from preferences.
    private var expandedGroups: Set<ProcessIdentity>
    private var collapsedDuringSearch = Set<ProcessIdentity>()
    private var selectedID: ProcessRowID?
    private var sort = ProcessSortState(column: .cpu, ascending: false)
    private var grouping: ProcessGrouping = .byApp
    /// Explicit column visibility choices from the header menu. Columns without a choice follow capability.
    private var columnOverrides: [String: Bool]
    /// True while the controller changes the outline itself, so delegate callbacks are not user actions.
    private var isApplyingModel = false

    init(dependencies: PageDependencies, defaults: UserDefaults? = nil) {
        self.dependencies = dependencies
        let fixtureSuite = dependencies.fixtureMode
            ? ProcessInfo.processInfo.environment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"]
            : nil
        self.defaults = defaults ?? fixtureSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let fixtureSuite {
            clearFixtureTableAutosave(named: "\(Self.autosaveName).\(fixtureSuite)")
        }
        if dependencies.fixtureMode,
           ProcessInfo.processInfo.arguments.contains("--ui-test-reset-expansion-state") {
            self.defaults.removeObject(forKey: ProcessGroupExpansionPersistence.defaultsKey)
            _ = self.defaults.synchronize()
        }
        outlineAutosaveName = dependencies.fixtureMode ? nil : Self.autosaveName
        expandedGroups = ProcessGroupExpansionPersistence.load(from: self.defaults)
        columnOverrides = self.defaults.dictionary(forKey: ProcessesViewController.columnVisibilityKey)
            as? [String: Bool] ?? [:]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: String(localized: "Processes"),
            subtitle: String(localized: "Live applications and background tasks grouped by their parent or app bundle.")
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

    private var lastFittedWidth: CGFloat = 0

    /// Validation renames the Process menu's Quit item to "Relaunch Finder"; other pages do not validate it,
    /// so restore its title when this page leaves the window.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        Self.menuItems(for: #selector(quitSelectedProcess(_:)), in: NSApp.mainMenu)
            .forEach { $0.title = String(localized: "Quit Process") }
    }

    private static func menuItems(for action: Selector, in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { item in
            (item.action == action ? [item] : []) + menuItems(for: action, in: item.submenu)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitNameColumn(force: false)
    }

    /// Name width that fills the visible table exactly, never below its minimum. Restored or hand-tuned
    /// widths from a wider window would otherwise leave Name wide enough to push the metric columns
    /// out of view.
    static func fittedNameWidth(visibleWidth: CGFloat, otherColumnWidths: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, (visibleWidth - otherColumnWidths).rounded(.down))
    }

    /// Refits Name when the visible width changes (window resize, first layout after restoring saved
    /// widths) or when column visibility changes. A Name width the user drags stays until the next change.
    private func fitNameColumn(force: Bool) {
        guard let clipWidth = outlineView.enclosingScrollView?.contentView.bounds.width, clipWidth > 0,
              let name = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ProcessColumn.name.rawValue))
        else { return }
        guard force || abs(clipWidth - lastFittedWidth) > 0.5 else { return }
        lastFittedWidth = clipWidth
        let others = outlineView.tableColumns.filter { !$0.isHidden && $0 !== name }.reduce(CGFloat(0)) { $0 + $1.width }
        let target = Self.fittedNameWidth(visibleWidth: clipWidth, otherColumnWidths: others, minimum: name.minWidth)
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    // MARK: - Configuration

    private func configureOutline() {
        outlineView.setAccessibilityIdentifier("process.table")
        outlineView.setAccessibilityLabel(String(localized: "Processes"))
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
            tableColumn.headerCell = PaddedTableHeaderCell(textCell: column.title)
            tableColumn.title = column.title
            tableColumn.width = Self.defaultWidth(for: column)
            tableColumn.minWidth = Self.minimumWidth(for: column)
            tableColumn.headerCell.alignment = column == .name || column == .user ? .left : .right
            if column == .cpu {
                // Process CPU is a share of the whole machine, unlike Activity Monitor's per-core percentages.
                tableColumn.headerToolTip = String(localized: "Share of total CPU capacity across all cores. 100% means every core is busy.")
            }
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableColumn.headerCell.setAccessibilityIdentifier(column.rawValue)
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        // Autosave after the columns exist so saved widths and order apply to them.
        outlineView.autosaveName = outlineAutosaveName
        outlineView.autosaveTableColumns = outlineAutosaveName != nil
        outlineView.headerView?.setAccessibilityIdentifier("process.table.header")
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
        searchItem.label = String(localized: "Search")
        searchItem.paletteLabel = String(localized: "Search Processes")
        searchItem.toolTip = String(localized: "Search by name, path, PID or user (⌘F)")
        searchItem.preferredWidthForSearchField = 220
        searchItem.searchField.placeholderString = String(localized: "Search processes")
        searchItem.searchField.setAccessibilityIdentifier("process.search")
        searchItem.searchField.setAccessibilityLabel(String(localized: "Search processes"))
        searchItem.searchField.delegate = self
        (searchItem.searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true

        quitButton.bezelStyle = .toolbar
        quitButton.target = self
        quitButton.action = #selector(quitSelectedProcess(_:))
        quitButton.setAccessibilityIdentifier("process.action.quit")
        quitButton.isEnabled = false
        quitItem.label = String(localized: "Quit")
        quitItem.paletteLabel = String(localized: "Quit Process")
        quitItem.toolTip = String(localized: "Quit the selected process (⌘⌥Q)")
        quitItem.view = quitButton

        forceQuitButton.bezelStyle = .toolbar
        forceQuitButton.target = self
        forceQuitButton.action = #selector(forceQuitSelectedProcess(_:))
        forceQuitButton.setAccessibilityIdentifier("process.action.force-quit")
        forceQuitButton.isEnabled = false
        forceQuitItem.label = String(localized: "Force Quit…")
        forceQuitItem.paletteLabel = String(localized: "Force Quit Process")
        forceQuitItem.toolTip = String(localized: "Force quit the selected process. Its child processes are not targeted.")
        forceQuitItem.view = forceQuitButton

        let byApp = NSMenuItem(title: String(localized: "Group by App"), action: #selector(setProcessGrouping(_:)), keyEquivalent: "")
        byApp.tag = 0
        byApp.target = self
        let flat = NSMenuItem(title: String(localized: "Flat List"), action: #selector(setProcessGrouping(_:)), keyEquivalent: "")
        flat.tag = 1
        flat.target = self
        groupingMenu.addItem(byApp)
        groupingMenu.addItem(flat)
        groupingMenu.autoenablesItems = false
        groupingItem.label = String(localized: "Grouping")
        groupingItem.paletteLabel = String(localized: "Grouping")
        groupingItem.toolTip = String(localized: "Group processes by app, or list them flat")
        groupingItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: String(localized: "Grouping"))
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
        let retainedExpansions = ProcessGroupExpansionPersistence.available(expandedGroups, in: snapshot.processGroups)
        if retainedExpansions != expandedGroups {
            expandedGroups = retainedExpansions
            persistExpandedGroups()
        }
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
                withoutAnimation { outlineView.collapseItem(item) }
            }
            shownChildren[id] = nil
        }

        // A level whose diff is longer than the limit is reloaded instead. Sampling reorders most rows on every
        // refresh, and one move per row costs more than a reload of that level.
        if let topOperations = ProcessRowModel.boundedOperations(from: topLevelIDs, to: output.topLevel,
                                                                 limit: Self.incrementalOperationLimit) {
            var childOperations: [(parent: ProcessRowID, operations: [ProcessRowDiffOperation<ProcessRowID>])] = []
            var reloadedChildLevels: [ProcessRowID] = []
            for id in output.topLevel {
                guard let shown = shownChildren[id], let wanted = output.children[id] else { continue }
                guard let operations = ProcessRowModel.boundedOperations(from: shown, to: wanted,
                                                                         limit: Self.incrementalOperationLimit) else {
                    reloadedChildLevels.append(id)
                    continue
                }
                if !operations.isEmpty { childOperations.append((id, operations)) }
            }
            // Rows change place instantly so the table never slides under the user.
            withoutAnimation {
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
            }
            for id in reloadedChildLevels {
                reloadChildLevel(id, wanted: output.children[id] ?? [])
            }
        } else {
            reloadTopLevel(output)
        }

        // Groups that are newly expanded: their members are inserted after the group row exists.
        for id in output.topLevel where shownChildren[id] == nil {
            guard let wanted = output.children[id], let item = items[id] else { continue }
            shownChildren[id] = wanted
            withoutAnimation { outlineView.expandItem(item) }
        }

        reloadChangedCells(previous: previousRows, next: output)
        rowsByID = output.rows
        items = items.filter { output.rows[$0.key] != nil }
        syncSelection(visible: visibleRowIDs)
        updateSelectionDetails()
    }

    /// Reloads the top level when its diff is too long to apply step by step. The reload collapses every group,
    /// so the expansion pass in `applyModel` restores the groups that `output` expands.
    private func reloadTopLevel(_ output: ProcessOutline) {
        withoutAnimation {
            for id in Array(shownChildren.keys) {
                if let item = items[id], outlineView.row(forItem: item) >= 0 {
                    outlineView.collapseItem(item)
                }
            }
        }
        shownChildren = [:]
        topLevelIDs = output.topLevel
        withoutAnimation { outlineView.reloadData() }
    }

    /// Reloads one expanded group's member rows in place when its diff is too long to apply step by step.
    private func reloadChildLevel(_ parent: ProcessRowID, wanted: [ProcessRowID]) {
        guard let item = items[parent] else { return }
        shownChildren[parent] = wanted
        withoutAnimation {
            let wasExpanded = outlineView.isItemExpanded(item)
            outlineView.reloadItem(item, reloadChildren: true)
            if wasExpanded, !outlineView.isItemExpanded(item) {
                outlineView.expandItem(item)
            }
        }
    }

    private var visibleRowIDs: [ProcessRowID] {
        topLevelIDs.flatMap { [$0] + (shownChildren[$0] ?? []) }
    }

    /// Applies one diff step to the outline and to the mirror, which must change together.
    private func perform(_ operation: ProcessRowDiffOperation<ProcessRowID>, parent: ProcessRowID?) {
        let parentItem: Any? = parent.flatMap { items[$0] }
        switch operation {
        case .remove(let index):
            mutateChildren(of: parent) { children in _ = children.remove(at: index) }
            outlineView.removeItems(at: IndexSet(integer: index), inParent: parentItem, withAnimation: [])
        case .insert(let id, let index):
            mutateChildren(of: parent) { children in children.insert(id, at: index) }
            outlineView.insertItems(at: IndexSet(integer: index), inParent: parentItem, withAnimation: [])
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

    /// Only a disclosure click by the user animates; everything the model applies is instant.
    private func animated(_ changes: () -> Void) {
        MotionPolicy.animate(changes)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }
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

    /// Applies the computed hidden states. Name refits only when a column's hidden state changed (or `forceFit`),
    /// so a Name width the user dragged survives every sample.
    @discardableResult
    private func applyColumnVisibility(forceFit: Bool = false) -> Bool {
        var changed = false
        for column in ProcessColumn.allCases where column.isHideable {
            guard let tableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) else { continue }
            let hidden = columnHidden(column)
            if tableColumn.isHidden != hidden {
                tableColumn.isHidden = hidden
                changed = true
            }
        }
        if changed || forceFit { fitNameColumn(force: true) }
        return changed
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
        defaults.set(columnOverrides, forKey: Self.columnVisibilityKey)
        applyColumnVisibility(forceFit: true)
    }

    // MARK: - Selection details

    private var selectedProcess: ProcessSnapshot? {
        selectedID.flatMap { processByIdentity[$0.identity] }
    }

    private var selectedPath: String? {
        guard let selectedID else { return nil }
        return rowsByID[selectedID]?.executablePath ?? selectedProcess?.executablePath
    }

    private var hasValidSelection: Bool {
        guard let selectedProcess else { return false }
        return !Self.isProtectedFromQuit(selectedProcess)
    }

    /// True when the selection is the current user's Finder, which offers Relaunch instead of Quit.
    private var selectionIsFinder: Bool {
        selectedProcess.map(Self.isRelaunchableFinder) ?? false
    }

    /// The current user's Finder. Like the system Force Quit window, Microgravity relaunches it rather than quitting it.
    static func isRelaunchableFinder(_ process: ProcessSnapshot) -> Bool {
        FinderProcess.matches(executablePath: process.executablePath, ownerUID: process.ownerUID,
                              currentUID: UInt32(getuid()))
    }

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
        let started = Self.startTimeFormatter.string(from: Self.startDate(process.id.startTime))
        let icon = row?.isGroup == true
            ? AppIconProvider.icon(forBundlePath: row?.iconBundlePath)
            : AppIconProvider.genericExecutableIcon()
        selectionBar.show(
            title: title,
            summary: String(localized: "PID \(process.id.pid) · \(owner) · \(path ?? String(localized: "Path unavailable"))"),
            identity: String(localized: "Started \(started)"),
            identityAccessibilityLabel: String(localized: "PID \(process.id.pid), started \(started)"),
            icon: icon
        )
        if Self.isRelaunchableFinder(process) {
            setActionsEnabled(quit: true, forceQuit: false, quitTitle: String(localized: "Relaunch"))
            quitButton.toolTip = String(localized: "Quit Finder and open it again")
            forceQuitButton.toolTip = String(localized: "Finder can be relaunched but not force quit.")
            return
        }
        let protected = Self.isProtectedFromQuit(process)
        setActionsEnabled(!protected)
        let reason = protected ? Self.systemProtectedMessage : nil
        quitButton.toolTip = reason
        forceQuitButton.toolTip = reason
    }

    /// Root-owned, PID 1, Microgravity itself and protected system locations are always refused by the
    /// action controllers, so their Quit controls stay disabled instead of offering an action that fails.
    static func isProtectedFromQuit(_ process: ProcessSnapshot) -> Bool {
        process.ownerUID == nil || process.ownerUID == 0 || process.id.pid <= 1 || process.id.pid == getpid()
            || HelperTerminationPolicy.isProtected(executablePath: process.executablePath, systemFlag: false)
    }

    /// The process start time as a `Date`, for the localized selection-bar label.
    private static func startDate(_ startTime: ProcessStartTime) -> Date {
        Date(timeIntervalSince1970: TimeInterval(startTime.secondsSinceEpoch) + TimeInterval(startTime.microseconds) / 1_000_000)
    }

    private func setActionsEnabled(_ enabled: Bool) {
        setActionsEnabled(quit: enabled, forceQuit: enabled, quitTitle: String(localized: "Quit"))
    }

    private func setActionsEnabled(quit: Bool, forceQuit: Bool, quitTitle: String) {
        quitButton.title = quitTitle
        quitItem.label = quitTitle
        quitButton.isEnabled = quit
        forceQuitButton.isEnabled = forceQuit
        quitItem.isEnabled = quit
        forceQuitItem.isEnabled = forceQuit
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
        persistExpandedGroups()
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
        persistExpandedGroups()
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

    /// Switches to Details and selects the exact live identity represented by the current row.
    @objc func showSelectedProcessInDetails(_ sender: Any?) {
        guard let selectedID, processByIdentity[selectedID.identity] != nil,
              let root = view.window?.contentViewController as? RootViewController else { return }
        root.showProcessInDetails(selectedID.identity)
    }

    private func persistExpandedGroups() {
        ProcessGroupExpansionPersistence.save(expandedGroups, to: defaults)
    }

    /// Focuses the toolbar search field (⌘F).
    @objc func focusProcessSearch(_ sender: Any?) {
        searchItem.beginSearchInteraction()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let action = item.action
        if action == #selector(quitSelectedProcess(_:)) {
            // The Process menu and context menu say what Quit does for Finder.
            (item as? NSMenuItem)?.title = selectionIsFinder
                ? String(localized: "Relaunch Finder") : String(localized: "Quit Process")
            return hasValidSelection || selectionIsFinder
        }
        if action == #selector(forceQuitSelectedProcess(_:)) {
            return hasValidSelection
        }
        if action == #selector(revealSelectedProcess(_:)) || action == #selector(copySelectedPath(_:)) {
            return selectedPath != nil
        }
        return true
    }

    /// Confirms, then quits and reopens Finder, like Relaunch in the system Force Quit window.
    private func requestFinderRelaunch(_ identity: ProcessIdentity) {
        Task { [weak self] in
            guard let self else { return }
            let response = await SheetAlert.present(
                on: view.window,
                style: .warning,
                messageText: String(localized: "Relaunch Finder?"),
                informativeText: String(localized: "Finder quits and opens again. Its open windows close and may reopen."),
                buttons: [String(localized: "Relaunch"), String(localized: "Cancel")],
                defaultButtonIdentifier: "process.relaunch-finder.confirm"
            )
            guard response == .alertFirstButtonReturn else { return }
            let result = await dependencies.processActions.relaunchFinder(identity: identity)
            if case .rejected(let reason, let detail) = result.outcome {
                let isStale = reason == .processExited || reason == .identityChanged
                if isStale { clearSelection() }
                await dependencies.monitoringStore.refreshNow()
                await SheetAlert.present(
                    on: view.window,
                    style: .informational,
                    messageText: String(localized: "Finder was not relaunched"),
                    informativeText: Self.rejectionMessage(reason, detail: detail, targetIsSystemOwned: false),
                    buttons: [String(localized: "OK")]
                )
                return
            }
            clearSelection()
            await dependencies.monitoringStore.refreshNow()
        }
    }

    private func requestTermination(force: Bool) {
        guard let selectedID, let process = processByIdentity[selectedID.identity] else {
            presentNotice(title: String(localized: "Process No Longer Available"),
                          message: String(localized: "The selected process is no longer available."))
            clearSelection()
            return
        }
        let identity = selectedID.identity
        if !force, Self.isRelaunchableFinder(process) {
            requestFinderRelaunch(identity)
            return
        }
        let name = process.name
        let targetIsSystemOwned = process.ownerUID == 0
        Task { [weak self] in
            guard let self else { return }
            // Both actions confirm first, like Activity Monitor. The confirm button is the destructive first button.
            let response: NSApplication.ModalResponse
            if force {
                response = await SheetAlert.present(
                    on: view.window,
                    style: .warning,
                    messageText: String(localized: "Confirm Force Quit"),
                    informativeText: String(localized: "Force quit \(name) (process \(identity.pid)) only. Its child processes are not targeted."),
                    buttons: [String(localized: "Force Quit"), String(localized: "Cancel")],
                    defaultButtonIdentifier: "process.force-quit.confirm",
                    destructiveButtonIndex: 0
                )
            } else {
                response = await SheetAlert.present(
                    on: view.window,
                    style: .warning,
                    messageText: String(localized: "Quit “\(name)”?"),
                    buttons: [String(localized: "Quit"), String(localized: "Cancel")],
                    defaultButtonIdentifier: "process.quit.confirm",
                    destructiveButtonIndex: 0
                )
            }
            guard response == .alertFirstButtonReturn else { return }
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
                    messageText: isStale ? String(localized: "Process No Longer Available") : String(localized: "Process action not completed"),
                    informativeText: message,
                    buttons: [String(localized: "OK")]
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
        case .invalidIdentity, .identityChanged, .processExited: base = String(localized: "The selected process changed or exited. No process was terminated.")
        case .currentProcess: base = String(localized: "Microgravity cannot terminate itself.")
        case .pidOne: base = String(localized: "The system’s launch process is protected.")
        case .protectedProcess: base = String(localized: "This process is protected.")
        case .differentUser: base = String(localized: "This process belongs to another user.")
        case .permissionDenied: base = String(localized: "Permission was denied.")
        case .helperUnavailable: base = String(localized: "The required helper is unavailable.")
        case .signalFailed: base = String(localized: "The operating system could not send the signal.")
        }
        if let detail, !detail.isEmpty { return "\(base) \(detail)" }
        return base
    }

    private func presentNotice(title: String, message: String) {
        Task { [weak self] in
            guard let self else { return }
            await SheetAlert.present(on: view.window, style: .informational, messageText: title,
                                     informativeText: message, buttons: [String(localized: "OK")])
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
        menu.addItem(contextItem(String(localized: "Quit Process"), #selector(quitSelectedProcess(_:))))
        menu.addItem(contextItem(String(localized: "Force Quit…"), #selector(forceQuitSelectedProcess(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem(String(localized: "Reveal in Finder"), #selector(revealSelectedProcess(_:))))
        menu.addItem(contextItem(String(localized: "Copy Path"), #selector(copySelectedPath(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem(String(localized: "Show in Details"), #selector(showSelectedProcessInDetails(_:))))
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

@MainActor
func clearFixtureTableAutosave(named autosaveName: String) {
    let defaults = UserDefaults.standard
    for prefix in ["NSTableView Columns v3 ", "NSTableView Sort Ordering v2 ", "NSTableView Supports v2 "] {
        defaults.removeObject(forKey: prefix + autosaveName)
    }
}
