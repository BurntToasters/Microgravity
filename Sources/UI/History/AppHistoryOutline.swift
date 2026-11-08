import AppKit

/// Owns the App History outline: applications at the top level, one child row per day.
///
/// Groups stay expanded unless the user collapses them; collapsed state survives refreshes.
/// Header clicks sort the applications and, within each application, its days.
@MainActor
final class AppHistoryOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Reference node so `NSOutlineView` can key expansion and selection on identity.
    private final class Node {
        let row: AppHistoryRow
        let icon: NSImage?
        let isApplication: Bool
        var children: [Node] = []

        init(row: AppHistoryRow, icon: NSImage?, isApplication: Bool) {
            self.row = row
            self.icon = icon
            self.isApplication = isApplication
        }
    }

    let scrollView: NSScrollView
    private let outline: NSOutlineView
    private let emptyState: EmptyStateView
    private var source: [AppHistoryGroup] = []
    private var roots: [Node] = []
    private var collapsedGroupIDs: Set<String> = []

    init(autosaveName: String? = "history.outline") {
        outline = NSOutlineView()
        outline.setAccessibilityIdentifier("history.table")
        outline.setAccessibilityLabel("App history by application and day")
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.selectionHighlightStyle = .regular
        outline.rowHeight = 28
        outline.intercellSpacing = .zero
        outline.gridStyleMask = []
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autosaveName = autosaveName
        outline.autosaveTableColumns = autosaveName != nil
        outline.headerView?.setAccessibilityIdentifier("history.table.header")

        for column in AppHistoryColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .application ? 140 : 72
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.headerCell.setAccessibilityIdentifier(column.rawValue)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            outline.addTableColumn(tableColumn)
        }
        outline.outlineTableColumn = outline.tableColumns.first

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll
        emptyState = EmptyStateView.install(in: scroll, symbolName: "clock.arrow.circlepath",
                                            title: "No app history yet")
        super.init()
        outline.dataSource = self
        outline.delegate = self
        // Starts with no rows; `update` returns early for unchanged input, so show the empty state here.
        emptyState.isHidden = false
    }

    /// Replaces the applications and days. Unchanged input is ignored, so the periodic refresh does not reload.
    func update(groups: [AppHistoryGroup]) {
        guard groups != source else { return }
        source = groups
        rebuild()
    }

    func setEmptyState(title: String, caption: String?) {
        emptyState.update(symbolName: "clock.arrow.circlepath", title: title, caption: caption)
    }

    private var sortOrder: AppHistorySortOrder? { AppHistorySortOrder(descriptor: outline.sortDescriptors.first) }

    private func rebuild() {
        let selectedID = (outline.item(atRow: outline.selectedRow) as? Node)?.row.id
        let order = sortOrder
        roots = AppHistorySort.ordered(source, row: \.total, by: order).map { group in
            let icon = AppIconProvider.icon(forBundlePath: group.executablePath)
            let node = Node(row: group.total, icon: icon, isApplication: true)
            node.children = AppHistorySort.ordered(group.days, row: { $0 }, by: order).map {
                Node(row: $0, icon: nil, isApplication: false)
            }
            return node
        }
        outline.reloadData()
        MotionPolicy.animate {
            for root in roots where !collapsedGroupIDs.contains(root.row.id) && !root.children.isEmpty {
                outline.expandItem(root)
            }
        }
        restoreSelection(selectedID)
        emptyState.isHidden = !source.isEmpty
    }

    private func restoreSelection(_ id: String?) {
        guard let id, let node = (roots + roots.flatMap(\.children)).first(where: { $0.row.id == id }) else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else {
            outline.deselectAll(nil)
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isApplication && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuild()
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let tableColumn,
              let column = AppHistoryColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let reuseIdentifier = NSUserInterfaceItemIdentifier("history.cell.\(column.rawValue)")
        let cell = outlineView.makeView(withIdentifier: reuseIdentifier, owner: self) as? AppHistoryCellView
            ?? AppHistoryCellView(frame: .zero)
        cell.identifier = reuseIdentifier
        cell.configure(
            text: node.row.values[column.index],
            accessibilityID: "\(node.row.id).\(column.rawValue)",
            column: column,
            icon: column == .application ? node.icon : nil
        )
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node, node.isApplication else { return }
        collapsedGroupIDs.remove(node.row.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node, node.isApplication else { return }
        collapsedGroupIDs.insert(node.row.id)
    }
}

@MainActor
private final class AppHistoryCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: AppIconProvider.pointSize),
            iconView.heightAnchor.constraint(equalToConstant: AppIconProvider.pointSize),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, accessibilityID: String, column: AppHistoryColumn, icon: NSImage?) {
        label.stringValue = text
        label.alignment = column.isNumeric ? .right : .left
        label.font = column.isNumeric
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        label.setAccessibilityIdentifier(accessibilityID)
        iconView.image = icon
        iconView.isHidden = icon == nil
    }
}
