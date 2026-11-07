import AppKit

/// Left rail of the Performance page: one selectable row per metric with its current value and a sparkline.
///
/// The rows are an `NSTableView`, so mouse selection and arrow keys come from AppKit. Each metric keeps one cell
/// for the life of the page and is updated in place every sample.
@MainActor
final class MetricRailView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Fires when the user selects a different metric with the mouse or the keyboard.
    var onSelect: ((PerformanceMetric) -> Void)?

    private let table = NSTableView()
    private var items: [MetricRailItem] = []
    private var cells: [PerformanceMetric: MetricRailCellView] = [:]
    private var isSyncingSelection = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("performance.rail.column"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 160
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 62
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("performance.rail")
        table.setAccessibilityLabel("Metrics")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Refreshes every row in place. Rows are rebuilt only when the metric list itself changes.
    func update(items newItems: [MetricRailItem], selectedMetric: PerformanceMetric) {
        let shapeChanged = newItems.map(\.metric) != items.map(\.metric)
        items = newItems
        if shapeChanged { table.reloadData() }
        for item in items { cells[item.metric]?.configure(item) }
        select(selectedMetric)
    }

    private func select(_ metric: PerformanceMetric) {
        guard let row = items.firstIndex(where: { $0.metric == metric }), table.selectedRow != row else { return }
        isSyncingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSyncingSelection = false
    }

    // MARK: NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let cell = cells[item.metric] ?? MetricRailCellView(metric: item.metric)
        cells[item.metric] = cell
        cell.configure(item)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MetricRailRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, items.indices.contains(table.selectedRow) else { return }
        onSelect?(items[table.selectedRow].metric)
    }
}

/// Title, value line and a 36 pt sparkline. The sparkline is removed, not zeroed, when there is no data.
@MainActor
private final class MetricRailCellView: NSTableCellView {
    private let metric: PerformanceMetric
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(wrappingLabelWithString: "")
    private let sparkline = MetricGraphView(style: .sparkline)
    private var withSparkline: [NSLayoutConstraint] = []
    private var withoutSparkline: [NSLayoutConstraint] = []
    private var showsSparkline = true

    init(metric: PerformanceMetric) {
        self.metric = metric
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .systemFont(ofSize: 11)
        valueLabel.textColor = .labelColor
        valueLabel.maximumNumberOfLines = 2
        valueLabel.lineBreakMode = .byWordWrapping
        super.init(frame: .zero)

        sparkline.setAccessibilityElement(false)
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        withSparkline = [
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sparkline.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: sparkline.leadingAnchor, constant: -8)
        ]
        withoutSparkline = [
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ]

        setAccessibilityIdentifier("performance.rail.\(metric.rawValue)")
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(sparkline)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            sparkline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sparkline.centerYAnchor.constraint(equalTo: centerYAnchor),
            sparkline.widthAnchor.constraint(equalToConstant: 84),
            sparkline.heightAnchor.constraint(equalToConstant: 36)
        ])
        NSLayoutConstraint.activate(withSparkline)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ item: MetricRailItem) {
        titleLabel.stringValue = item.metric.title
        valueLabel.stringValue = item.valueText
        valueLabel.textColor = item.isValueUnavailable ? .secondaryLabelColor : .labelColor
        let hasSparkline = !item.sparkline.isEmpty
        if hasSparkline != showsSparkline {
            showsSparkline = hasSparkline
            NSLayoutConstraint.deactivate(hasSparkline ? withoutSparkline : withSparkline)
            NSLayoutConstraint.activate(hasSparkline ? withSparkline : withoutSparkline)
        }
        sparkline.isHidden = !hasSparkline
        sparkline.update(series: item.sparkline, maximum: item.sparklineMaximum,
                         mapping: .index(capacity: PerformancePresenter.sparklineSampleCount))
        setAccessibilityLabel(item.accessibilityLabel)
        toolTip = hasSparkline ? nil : "\(metric.title) has no data to plot"
    }
}

/// Selection drawn as a soft accent pill, so the cell text keeps its label colors when selected.
@MainActor
private final class MetricRailRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}
