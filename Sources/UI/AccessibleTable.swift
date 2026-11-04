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

struct AccessibleTableRow {
    let id: String
    let values: [String]
}

@MainActor
final class AccessibleTableModel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let columns: [TableColumnSpec]
    private(set) var rows: [AccessibleTableRow] = []
    var onSelectionChanged: ((String?) -> Void)?
    var onSortChanged: (() -> Void)?

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
        self.rows = rows
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn,
              let columnIndex = columns.firstIndex(where: { $0.key == tableColumn.identifier.rawValue }) else { return nil }
        let item = rows[row]
        let text = NSTextField(labelWithString: columnIndex < item.values.count ? item.values[columnIndex] : "")
        text.font = .systemFont(ofSize: 12)
        text.alignment = columns[columnIndex].alignment
        text.lineBreakMode = .byTruncatingMiddle
        text.maximumNumberOfLines = 1
        text.setAccessibilityIdentifier("\(item.id).\(columns[columnIndex].key)")
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(item.id + "." + columns[columnIndex].key)
        cell.setAccessibilityIdentifier(item.id + "." + columns[columnIndex].key)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
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
        onSortChanged?()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              rows.indices.contains(table.selectedRow) else {
            onSelectionChanged?(nil)
            return
        }
        onSelectionChanged?(rows[table.selectedRow].id)
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
