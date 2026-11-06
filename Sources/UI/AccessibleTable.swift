import AppKit

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

struct AccessibleTableRow {
    let id: String
    let values: [String]
    let sortKeys: [ComparableSortKey]

    init(id: String, values: [String], sortKeys: [ComparableSortKey]? = nil) {
        self.id = id
        self.values = values
        self.sortKeys = sortKeys ?? values.map(ComparableSortKey.text)
    }
}

@MainActor
final class AccessibleTableModel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let columns: [TableColumnSpec]
    private var sourceRows: [AccessibleTableRow] = []
    private(set) var rows: [AccessibleTableRow] = []
    var onSelectionChanged: ((String?) -> Void)?

    init(table: NSTableView, columns: [TableColumnSpec]) {
        self.columns = columns
        super.init()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 31
        table.intercellSpacing = NSSize(width: 0, height: 1)
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
    }

    func replaceRows(_ rows: [AccessibleTableRow], in table: NSTableView) {
        let selectedID = selectedRowID(in: table)
        sourceRows = rows
        self.rows = sortedRows(sourceRows, descriptors: table.sortDescriptors)
        table.reloadData()
        restoreSelection(selectedID, in: table)
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
        cell.identifier = reuseIdentifier
        cell.setAccessibilityIdentifier("\(item.id).cell.\(column.key)")
        cell.configure(
            value: columnIndex < item.values.count ? item.values[columnIndex] : "",
            accessibilityID: "\(item.id).\(column.key)",
            alignment: column.alignment
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        if rows.indices.contains(row) {
            view.setAccessibilityIdentifier(rows[row].id)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selectedID = selectedRowID(in: tableView)
        rows = sortedRows(sourceRows, descriptors: tableView.sortDescriptors)
        tableView.reloadData()
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
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

@MainActor
private final class AccessibleTableCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(value: String, accessibilityID: String, alignment: NSTextAlignment) {
        label.stringValue = value
        label.alignment = alignment
        label.setAccessibilityIdentifier(accessibilityID)
    }
}

@MainActor
func makeAccessibleTable(identifier: String, horizontalScroll: Bool = true) -> (NSTableView, NSScrollView) {
    let table = NSTableView()
    table.setAccessibilityIdentifier(identifier)
    table.allowsColumnReordering = false
    table.selectionHighlightStyle = .regular
    table.headerView?.setAccessibilityIdentifier(identifier + ".header")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = horizontalScroll
    scroll.drawsBackground = false
    scroll.borderType = .lineBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return (table, scroll)
}
