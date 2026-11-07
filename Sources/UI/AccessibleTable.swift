import AppKit

/// Describes one table column. Right-aligned columns are treated as numeric (monospaced digits).
struct TableColumnSpec {
    let key: String
    let title: String
    let width: CGFloat
    let alignment: NSTextAlignment

    init(_ key: String, _ title: String, width: CGFloat = 150, alignment: NSTextAlignment = .left) {
        self.key = key
        self.title = title
        self.width = width
        self.alignment = alignment
    }

    /// True for right-aligned columns, which use monospaced digits.
    var isNumeric: Bool { alignment == .right }
}

enum ComparableSortKey {
    case text(String)
    case number(Double)
    case none

    static func numeric(_ value: Double?) -> Self {
        guard let value, value.isFinite else { return .none }
        return .number(value)
    }

    func compare(to other: Self) -> ComparisonResult {
        switch (self, other) {
        case (.text(let left), .text(let right)):
            return left.localizedStandardCompare(right)
        case (.number(let left), .number(let right)):
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case (.none, .none):
            return .orderedSame
        case (.none, _):
            return .orderedDescending
        case (_, .none):
            return .orderedAscending
        case (.text, .number):
            return .orderedAscending
        case (.number, .text):
            return .orderedDescending
        }
    }
}

/// One table row. `id` is the row's identity: selection, row views and diffing all follow it.
struct AccessibleTableRow {
    let id: String
    let values: [String]
    let sortKeys: [ComparableSortKey]
    /// Optional icon for the first column; shown only when the model was built with `showsIconsInFirstColumn`.
    let icon: NSImage?

    init(id: String, values: [String], sortKeys: [ComparableSortKey]? = nil, icon: NSImage? = nil) {
        self.id = id
        self.values = values
        self.sortKeys = sortKeys ?? values.map(ComparableSortKey.text)
        self.icon = icon
    }

    /// Whether cells would look identical; used to decide which rows need a reload.
    fileprivate func hasSameContent(as other: Self) -> Bool {
        values == other.values && icon === other.icon
    }
}

/// Data source and delegate for an `NSTableView` built with `makeAccessibleTable`.
///
/// `replaceRows(_:in:)` diffs by row ID: unchanged rows are not reloaded, changed rows are reloaded
/// in place, and inserts and removals use row updates. A reorder (for example a sort change) falls
/// back to a full reload. Selection follows the row ID across all of these.
///
/// Columns can be hidden with `setColumnHidden(_:_:)` or from the header's context menu. Autosave
/// is enabled with `autosaveName`. With no rows, an `EmptyStateView` is shown over the scroll view.
@MainActor
final class AccessibleTableModel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("accessible.row")

    private let columns: [TableColumnSpec]
    private let showsIconsInFirstColumn: Bool
    private weak var table: NSTableView?
    private var sourceRows: [AccessibleTableRow] = []
    private(set) var rows: [AccessibleTableRow] = []
    private let columnMenu = NSMenu()
    private var emptyState: EmptyStateView?
    private var emptyStateConfiguration = EmptyStateConfiguration(
        symbolName: "tray", title: "Nothing to show", caption: nil
    )
    var onSelectionChanged: ((String?) -> Void)?

    /// - Parameters:
    ///   - autosaveName: When set, column widths, order and visibility persist under this name.
    ///   - showsIconsInFirstColumn: Reserves a 16 pt icon slot in the first column and shows `AccessibleTableRow.icon`.
    init(table: NSTableView, columns: [TableColumnSpec], autosaveName: String? = nil,
         showsIconsInFirstColumn: Bool = false) {
        self.columns = columns
        self.showsIconsInFirstColumn = showsIconsInFirstColumn
        self.table = table
        super.init()
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.gridColor = .separatorColor
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = min(spec.width, 72)
            column.headerCell.alignment = spec.alignment
            column.headerCell.setAccessibilityIdentifier(spec.key)
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.key, ascending: true)
            table.addTableColumn(column)
        }
        if let autosaveName {
            table.autosaveName = autosaveName
            table.autosaveTableColumns = true
        }
        columnMenu.delegate = self
        table.headerView?.menu = columnMenu
        updateEmptyState()
    }

    /// Replaces the rows, diffing against the current rows. Selection is kept by row ID.
    func replaceRows(_ rows: [AccessibleTableRow], in table: NSTableView) {
        let selectedID = selectedRowID(in: table)
        sourceRows = rows
        applyRows(sortedRows(sourceRows, descriptors: table.sortDescriptors), in: table)
        restoreSelection(selectedID, in: table)
        updateEmptyState()
    }

    /// Sets the placeholder shown when there are no rows. Call again whenever the reason changes
    /// (for example "No processes match \"x\"" versus "Discovery failed").
    func configureEmptyState(symbolName: String = "tray", title: String, caption: String? = nil) {
        emptyStateConfiguration = EmptyStateConfiguration(symbolName: symbolName, title: title, caption: caption)
        updateEmptyState()
    }

    /// Hides or shows a column by its key. Hidden columns keep their place and width.
    func setColumnHidden(_ key: String, _ hidden: Bool) {
        column(forKey: key)?.isHidden = hidden
    }

    /// Whether the column with `key` is currently hidden.
    func isColumnHidden(_ key: String) -> Bool {
        column(forKey: key)?.isHidden ?? false
    }

    /// Keys of the visible columns, in display order.
    var visibleColumnKeys: [String] {
        table?.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } ?? []
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn,
              let columnIndex = columns.firstIndex(where: { $0.key == tableColumn.identifier.rawValue }) else { return nil }
        let item = rows[row]
        let column = columns[columnIndex]
        let reuseIdentifier = NSUserInterfaceItemIdentifier("accessible.cell.\(column.key)")
        let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self) as? AccessibleTableCellView
            ?? AccessibleTableCellView(frame: .zero)
        let isIconColumn = columnIndex == 0 && showsIconsInFirstColumn
        cell.identifier = reuseIdentifier
        cell.setAccessibilityIdentifier("\(item.id).cell.\(column.key)")
        cell.configure(
            value: columnIndex < item.values.count ? item.values[columnIndex] : "",
            accessibilityID: "\(item.id).\(column.key)",
            alignment: column.alignment,
            isNumeric: column.isNumeric,
            icon: isIconColumn ? item.icon : nil,
            showsIconSlot: isIconColumn
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? NSTableRowView
            ?? NSTableRowView()
        view.identifier = Self.rowIdentifier
        if rows.indices.contains(row) {
            view.setAccessibilityIdentifier(rows[row].id)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selectedID = selectedRowID(in: tableView)
        applyRows(sortedRows(sourceRows, descriptors: tableView.sortDescriptors), in: tableView)
        restoreSelection(selectedID, in: tableView)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              rows.indices.contains(table.selectedRow) else {
            onSelectionChanged?(nil)
            return
        }
        onSelectionChanged?(rows[table.selectedRow].id)
    }

    /// Header context menu: one checkable item per column. The last visible column cannot be hidden.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        let visibleCount = table.tableColumns.filter { !$0.isHidden }.count
        for column in table.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumnFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.identifier.rawValue
            item.state = column.isHidden ? .off : .on
            item.isEnabled = column.isHidden || visibleCount > 1
            menu.addItem(item)
        }
    }

    @objc private func toggleColumnFromMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        setColumnHidden(key, !isColumnHidden(key))
    }

    /// Applies `updated` to the table. Rows are only inserted, removed or reloaded when the table can
    /// describe the change as updates (same survivors in the same order); anything else reloads.
    private func applyRows(_ updated: [AccessibleTableRow], in table: NSTableView) {
        let previous = rows
        rows = updated
        let previousIDs = previous.map(\.id)
        let updatedIDs = updated.map(\.id)
        let previousSet = Set(previousIDs)
        let updatedSet = Set(updatedIDs)
        let canDiff = table.numberOfRows == previous.count
            && previousSet.count == previousIDs.count
            && updatedSet.count == updatedIDs.count
            && previousIDs.filter(updatedSet.contains) == updatedIDs.filter(previousSet.contains)
        guard canDiff else {
            table.reloadData()
            return
        }

        let removed = IndexSet(previousIDs.indices.filter { !updatedSet.contains(previousIDs[$0]) })
        let inserted = IndexSet(updatedIDs.indices.filter { !previousSet.contains(updatedIDs[$0]) })
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        // Changed survivors, as indexes in the updated order (inserted rows are already fresh).
        let changed = IndexSet(updated.indices.filter { index in
            guard let old = previousByID[updated[index].id] else { return false }
            return !old.hasSameContent(as: updated[index])
        })
        guard !removed.isEmpty || !inserted.isEmpty || !changed.isEmpty else { return }

        if !removed.isEmpty || !inserted.isEmpty {
            table.beginUpdates()
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            table.endUpdates()
        }
        if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    private func updateEmptyState() {
        guard let table, let scroll = table.enclosingScrollView else { return }
        let configuration = emptyStateConfiguration
        if let emptyState {
            emptyState.update(symbolName: configuration.symbolName, title: configuration.title,
                              caption: configuration.caption)
        } else {
            emptyState = EmptyStateView.install(in: scroll, symbolName: configuration.symbolName,
                                                title: configuration.title, caption: configuration.caption)
        }
        emptyState?.isHidden = !rows.isEmpty
    }

    private func column(forKey key: String) -> NSTableColumn? {
        table?.tableColumns.first { $0.identifier.rawValue == key }
    }

    private func sortedRows(_ rows: [AccessibleTableRow], descriptors: [NSSortDescriptor]) -> [AccessibleTableRow] {
        guard let descriptor = descriptors.first, let key = descriptor.key,
              let columnIndex = columns.firstIndex(where: { $0.key == key }) else { return rows }
        return rows.sorted { left, right in
            let leftKey = sortKey(for: left, at: columnIndex)
            let rightKey = sortKey(for: right, at: columnIndex)
            if case .none = leftKey, case .none = rightKey { return left.id < right.id }
            if case .none = leftKey { return false }
            if case .none = rightKey { return true }
            let comparison = leftKey.compare(to: rightKey)
            if comparison == .orderedSame { return left.id < right.id }
            return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func sortKey(for row: AccessibleTableRow, at index: Int) -> ComparableSortKey {
        guard row.sortKeys.indices.contains(index) else {
            return row.values.indices.contains(index) ? .text(row.values[index]) : .none
        }
        return row.sortKeys[index]
    }

    private func selectedRowID(in table: NSTableView) -> String? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
    }

    private func restoreSelection(_ rowID: String?, in table: NSTableView) {
        guard let rowID, let row = rows.firstIndex(where: { $0.id == rowID }) else {
            table.deselectAll(nil)
            return
        }
        guard table.selectedRowIndexes != IndexSet(integer: row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

private struct EmptyStateConfiguration {
    let symbolName: String
    let title: String
    let caption: String?
}

@MainActor
private final class AccessibleTableCellView: NSTableCellView {
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
        iconView.isHidden = true

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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    func configure(value: String, accessibilityID: String, alignment: NSTextAlignment,
                   isNumeric: Bool, icon: NSImage?, showsIconSlot: Bool) {
        label.stringValue = value
        label.alignment = alignment
        label.font = isNumeric
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        label.setAccessibilityIdentifier(accessibilityID)
        iconView.image = icon
        iconView.isHidden = !showsIconSlot
    }
}

@MainActor
func makeAccessibleTable(identifier: String, horizontalScroll: Bool = true) -> (NSTableView, NSScrollView) {
    let table = NSTableView()
    table.setAccessibilityIdentifier(identifier)
    table.allowsColumnReordering = false
    table.selectionHighlightStyle = .regular
    table.style = .inset
    table.headerView?.setAccessibilityIdentifier(identifier + ".header")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = horizontalScroll
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return (table, scroll)
}
