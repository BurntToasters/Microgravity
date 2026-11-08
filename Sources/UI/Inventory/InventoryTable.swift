import AppKit

/// Table for the Startup and Services pages. Rows are read-only; the selection drives the path bar.
///
/// It is a plain `NSTableView` rather than `AccessibleTableModel` because the Status column draws a colored
/// dot before its text, which that model's cells do not support. Look and behaviour otherwise follow it:
/// `.inset` style, 28 pt rows, header sorting, autosaved column widths, a centered empty state.
@MainActor
final class InventoryTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView: NSScrollView
    private let table: NSTableView
    private let emptyState: EmptyStateView
    private var source: [InventoryRow] = []
    private var rows: [InventoryRow] = []
    /// Fires with the selected row ID, or nil when the selection is cleared.
    var onSelectionChanged: ((String?) -> Void)?

    init(identifier: String, autosaveName: String?, accessibilityLabel: String) {
        let table = NSTableView()
        table.setAccessibilityIdentifier(identifier)
        table.setAccessibilityLabel(accessibilityLabel)
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.selectionHighlightStyle = .regular
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if let autosaveName {
            table.autosaveName = autosaveName
            table.autosaveTableColumns = true
        }
        table.headerView?.setAccessibilityIdentifier(identifier + ".header")
        for column in InventoryColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 72
            tableColumn.headerCell.setAccessibilityIdentifier(column.rawValue)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll
        emptyState = EmptyStateView.install(in: scroll, symbolName: "tray", title: "Nothing to show")
        super.init()
        table.dataSource = self
        table.delegate = self
        // Starts with no rows; `update` returns early for unchanged input, so show the empty state here.
        emptyState.isHidden = false
    }

    var selectedRowID: String? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
    }

    /// Replaces the rows; unchanged input is ignored so the periodic refresh does not reload the table.
    func update(rows: [InventoryRow]) {
        guard rows != source else { return }
        source = rows
        rebuild()
    }

    func setEmptyState(title: String, caption: String?) {
        emptyState.update(symbolName: "tray", title: title, caption: caption)
    }

    private func rebuild() {
        let selected = selectedRowID
        let order = table.sortDescriptors.first
        let column = order?.key.flatMap { InventoryColumn(rawValue: $0) }
        rows = InventoryRows.ordered(source, by: column, ascending: order?.ascending ?? true)
        table.reloadData()
        restoreSelection(selected)
        emptyState.isHidden = !source.isEmpty
    }

    private func restoreSelection(_ id: String?) {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else {
            table.deselectAll(nil)
            return
        }
        guard table.selectedRow != index else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn,
              let column = InventoryColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = rows[row]
        let reuseIdentifier = NSUserInterfaceItemIdentifier("inventory.cell.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self) as? InventoryCellView
            ?? InventoryCellView(frame: .zero)
        cell.identifier = reuseIdentifier
        cell.configure(
            text: item.text(column),
            accessibilityID: "\(item.id).\(column.rawValue)",
            icon: column == .name ? AppIconProvider.icon(forBundlePath: item.iconBundlePath) : nil,
            tone: column == .state ? item.tone : nil
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?(selectedRowID)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuild()
    }
}

extension InventoryStatusTone {
    /// The shared dot color. Stopped (`caution`) shares Settings' orange `attention` tone.
    var statusTone: StatusTone {
        switch self {
        case .positive: .positive
        case .caution: .attention
        case .neutral: .neutral
        }
    }
}

@MainActor
private final class InventoryCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let dot = StatusDotView()
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

        dot.setAccessibilityElement(false)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isHidden = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(dot)
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

    func configure(text: String, accessibilityID: String, icon: NSImage?, tone: InventoryStatusTone?) {
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.setAccessibilityIdentifier(accessibilityID)
        iconView.image = icon
        iconView.isHidden = icon == nil
        dot.isHidden = tone == nil
        if let tone { dot.tone = tone.statusTone }
    }
}
