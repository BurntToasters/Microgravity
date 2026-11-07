import AppKit

/// Detail card for the selected metric: title and current value, time window, the big graph (or the CPU
/// processor grid), a stats grid, and the metric's own sections (interfaces, memory pressure, swap).
///
/// The card scrolls vertically when the window is shorter than its content. Nothing scrolls horizontally.
@MainActor
final class MetricDetailViewController: NSViewController {
    /// Fires when the user picks another time window in the card header.
    var onWindowChange: ((PerformanceWindow) -> Void)?
    /// Fires when the CPU control switches between the overall graph and the processor grid.
    var onCPUModeChange: ((CPUDetailMode) -> Void)?

    private let scrollView = NSScrollView()
    private let card = PerformanceCardView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let bigValueLabel = NSTextField(labelWithString: "")
    private let cpuModeControl = NSSegmentedControl(labels: ["Overall", "Logical Processors"],
                                                    trackingMode: .selectOne, target: nil, action: nil)
    private let windowPicker = NSSegmentedControl(labels: PerformanceWindow.allCases.map(\.title),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "")
    private let banner = StatusBannerView(style: .info)
    private let graph = MetricGraphView(style: .detail)
    private let coreGrid = CoreGridView()
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let statsGrid = MetricStatsGridView()
    private let interfaceSection = NSStackView()
    private let memorySection = NSStackView()
    private let pressureBlock = NSStackView()
    private let pressureChip = StateChipView()
    private let pressureStrip = MemoryPressureStripView()
    private let swapBlock = NSStackView()
    private let swapValueLabel = NSTextField(labelWithString: "")
    private let swapBar = CapacityBarView(tint: .systemPurple)
    private let swapGraph = MetricGraphView(style: .sparkline)

    override func loadView() {
        let root = NSView()
        view = root

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        bigValueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        bigValueLabel.textColor = .labelColor
        bigValueLabel.alignment = .right
        bigValueLabel.lineBreakMode = .byTruncatingTail
        // Header text must give way before the card does: at narrow widths the card keeps its width and the text truncates.
        for field in [titleLabel, subtitleLabel, bigValueLabel] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        cpuModeControl.segmentStyle = .rounded
        cpuModeControl.target = self
        cpuModeControl.action = #selector(cpuModePicked(_:))
        cpuModeControl.setAccessibilityIdentifier("performance.cpu.mode")
        cpuModeControl.setAccessibilityLabel("CPU view")
        windowPicker.segmentStyle = .rounded
        windowPicker.target = self
        windowPicker.action = #selector(windowPicked(_:))
        windowPicker.setAccessibilityIdentifier("performance.window")
        windowPicker.setAccessibilityLabel("Graph time window")

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .labelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.maximumNumberOfLines = 0
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, Self.spacer(), bigValueLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let subtitleRow = NSStackView(views: [subtitleLabel, Self.spacer(), windowPicker])
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = 8
        let controls = NSStackView(views: [cpuModeControl, Self.spacer()])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 240).isActive = true
        graph.setAccessibilityElement(true)
        coreGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        coreGrid.setAccessibilityIdentifier("performance.graph.cpu-cores")

        buildPressureBlock()
        buildSwapBlock()
        memorySection.orientation = .horizontal
        memorySection.alignment = .top
        memorySection.distribution = .fillEqually
        memorySection.spacing = 16
        memorySection.addArrangedSubview(pressureBlock)
        memorySection.addArrangedSubview(swapBlock)

        interfaceSection.orientation = .vertical
        interfaceSection.alignment = .leading
        interfaceSection.spacing = 6
        let interfaceTitle = Self.sectionTitle("Interfaces")
        interfaceSection.addArrangedSubview(interfaceTitle)
        Self.fillWidth(interfaceTitle, in: interfaceSection)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for item in [header, subtitleRow, controls, stateLabel, banner, graph, coreGrid, captionLabel,
                     statsGrid, interfaceSection, memorySection] as [NSView] {
            Self.addFullWidth(item, to: contentStack)
        }

        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        let document = PerformanceFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(card)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        root.addSubview(scrollView)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            card.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            card.topAnchor.constraint(equalTo: document.topAnchor),
            card.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    /// Applies one metric's model. Called every sample, so it updates views in place.
    func update(_ model: MetricDetailModel) {
        titleLabel.stringValue = model.title
        subtitleLabel.stringValue = model.subtitle
        bigValueLabel.stringValue = model.bigValue
        bigValueLabel.textColor = model.isBigValueUnavailable ? .secondaryLabelColor : .labelColor
        bigValueLabel.setAccessibilityIdentifier(model.bigValueIdentifier ?? "performance.detail.value")

        windowPicker.selectedSegment = PerformanceWindow.allCases.firstIndex(of: model.window) ?? 0
        cpuModeControl.isHidden = model.metric != .cpu
        cpuModeControl.selectedSegment = model.cpuMode.rawValue

        stateLabel.isHidden = model.stateText == nil
        stateLabel.stringValue = model.stateText ?? ""
        stateLabel.setAccessibilityIdentifier(model.stateIdentifier ?? "performance.detail.state")
        if let banner = model.banner {
            self.banner.setMessage(banner.message, style: banner.style)
        } else {
            self.banner.setMessage(nil)
        }

        let showsCores = model.metric == .cpu && model.cpuMode == .logicalProcessors
        graph.isHidden = showsCores
        graph.setAccessibilityIdentifier(model.graphIdentifier)
        graph.setAccessibilityLabel(model.graphAccessibilityLabel)
        graph.update(series: model.series, maximum: model.maximum, mapping: .time(model.timeSpan),
                     topLabel: model.topLabel, spanLabel: model.spanLabel)

        coreGrid.isHidden = !showsCores
        coreGrid.update(cores: model.cores, mapping: .time(model.timeSpan))

        captionLabel.isHidden = model.caption == nil
        captionLabel.stringValue = model.caption ?? ""
        captionLabel.setAccessibilityIdentifier(model.captionIdentifier ?? "performance.detail.caption")
        captionLabel.setAccessibilityLabel(model.captionAccessibilityLabel)

        statsGrid.update(model.stats)

        interfaceSection.isHidden = model.metric != .network
        if model.metric == .network { updateInterfaces(model.interfaces) }

        memorySection.isHidden = model.memory == nil
        if let memory = model.memory { updateMemory(memory, timeSpan: model.timeSpan) }
    }

    // MARK: Sections

    private func buildPressureBlock() {
        pressureBlock.orientation = .vertical
        pressureBlock.alignment = .leading
        pressureBlock.spacing = 6
        pressureBlock.setAccessibilityElement(true)
        pressureBlock.setAccessibilityRole(.group)
        pressureBlock.setAccessibilityLabel("Memory pressure")
        pressureBlock.setAccessibilityIdentifier("performance.graph.memory-pressure")
        pressureChip.label.setAccessibilityIdentifier("performance.memory-pressure.state")
        pressureStrip.setAccessibilityIdentifier("performance.memory-pressure.graph")
        let title = Self.sectionTitle("Memory pressure")
        let caption = NSTextField(wrappingLabelWithString: "Normal, warning, and critical samples over the graph window.")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 0
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pressureBlock.addArrangedSubview(title)
        pressureBlock.addArrangedSubview(pressureChip)
        Self.addFullWidth(pressureStrip, to: pressureBlock)
        Self.addFullWidth(caption, to: pressureBlock)
    }

    private func buildSwapBlock() {
        swapBlock.orientation = .vertical
        swapBlock.alignment = .leading
        swapBlock.spacing = 6
        swapBlock.setAccessibilityElement(true)
        swapBlock.setAccessibilityRole(.group)
        swapBlock.setAccessibilityLabel("Swap")
        swapBlock.setAccessibilityIdentifier("performance.graph.swap")
        swapValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        swapValueLabel.textColor = .labelColor
        swapValueLabel.lineBreakMode = .byTruncatingTail
        swapValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        swapValueLabel.setAccessibilityIdentifier("performance.swap.value")
        swapGraph.setAccessibilityIdentifier("performance.swap.graph")
        swapGraph.setAccessibilityLabel("Swap used over time")
        swapBar.setAccessibilityLabel("Swap used against total")
        swapBlock.addArrangedSubview(Self.sectionTitle("Swap"))
        swapBlock.addArrangedSubview(swapValueLabel)
        Self.addFullWidth(swapBar, to: swapBlock)
        Self.addFullWidth(swapGraph, to: swapBlock)
        swapGraph.translatesAutoresizingMaskIntoConstraints = false
        swapGraph.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    private func updateMemory(_ memory: MemoryDetailModel, timeSpan: TimeInterval) {
        pressureChip.setState(text: memory.pressureText, tint: Self.tint(for: memory.pressureLevel))
        pressureChip.toolTip = memory.pressureText
        pressureBlock.setAccessibilityValue(memory.pressureText)
        pressureStrip.update(samples: memory.pressureSamples, span: timeSpan)
        pressureStrip.setAccessibilityLabel("Memory pressure history, \(memory.pressureText)")

        swapValueLabel.stringValue = memory.swapValue
        swapBar.setFraction(memory.swapFraction)
        swapBar.setAccessibilityValue(memory.swapValue)
        swapGraph.update(series: memory.swapSeries.map { [$0] } ?? [], maximum: memory.swapMaximum,
                         mapping: .time(timeSpan))
    }

    private func updateInterfaces(_ rows: [NetworkInterfaceRow]) {
        for view in interfaceSection.arrangedSubviews.dropFirst() {
            interfaceSection.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if rows.isEmpty {
            let empty = Self.caption("No network interfaces reported.")
            interfaceSection.addArrangedSubview(empty)
            Self.fillWidth(empty, in: interfaceSection)
            return
        }
        for row in rows {
            let view = makeInterfaceRow(row)
            interfaceSection.addArrangedSubview(view)
            Self.fillWidth(view, in: interfaceSection)
        }
    }

    private func makeInterfaceRow(_ row: NetworkInterfaceRow) -> NSView {
        let name = NSTextField(labelWithString: row.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        let membership = Self.caption(row.membership)
        let left = NSStackView(views: [name, membership])
        left.orientation = .vertical
        left.alignment = .width
        left.spacing = 2

        let rates = NSTextField(labelWithString: row.rates)
        rates.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rates.textColor = .labelColor
        rates.alignment = .right
        rates.lineBreakMode = .byTruncatingTail
        let totals = Self.caption(row.totals)
        totals.alignment = .right
        let right = NSStackView(views: [rates, totals])
        right.orientation = .vertical
        right.alignment = .width
        right.spacing = 2

        let container = NSStackView(views: [left, Self.spacer(), right])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        for view in [left, right, container] as [NSView] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        for label in [name, membership, rates, totals] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel("\(row.name), \(row.rates), \(row.totals), \(row.membership)")
        container.setAccessibilityIdentifier("performance.network.interface.\(row.name)")
        return container
    }

    // MARK: Actions

    @objc private func windowPicked(_ sender: NSSegmentedControl) {
        let windows = PerformanceWindow.allCases
        guard windows.indices.contains(sender.selectedSegment) else { return }
        onWindowChange?(windows[sender.selectedSegment])
    }

    @objc private func cpuModePicked(_ sender: NSSegmentedControl) {
        onCPUModeChange?(CPUDetailMode(rawValue: sender.selectedSegment) ?? .overall)
    }

    // MARK: Helpers

    private static func tint(for level: MemoryPressureLevel?) -> NSColor {
        switch level {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case nil: return .tertiaryLabelColor
        }
    }

    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func fillWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

/// Grey-on-tint state pill with a colored dot. The text field is exposed as `label` for identifiers.
@MainActor
private final class StateChipView: NSView {
    let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .tertiaryLabelColor

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setState(text: String, tint: NSColor) {
        label.stringValue = text
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        tint.withAlphaComponent(0.16).setFill()
        pill.fill()
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 9, y: bounds.midY - 4, width: 8, height: 8)).fill()
    }
}

/// Stats as label-over-value cells in an NSGridView. Column count follows the width: 1 to 3.
///
/// Each cell lays out its own label and value by frame. Its width comes only from the grid column, so a long
/// value truncates inside the card rather than widening it. Cells are rebuilt only when the set of labels changes;
/// otherwise values are updated in place so the accessibility focus does not jump every sample.
@MainActor
private final class MetricStatsGridView: NSView {
    private var keys: [String] = []
    private var cells: [MetricStatCellView] = []
    private var gridView: NSGridView?
    private var columns = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ stats: [MetricStat]) {
        let newKeys = stats.map(\.label)
        let structureChanged = newKeys != keys || gridView == nil
        if newKeys != keys {
            keys = newKeys
            cells = stats.map { _ in MetricStatCellView() }
        }
        for (cell, stat) in zip(cells, stats) {
            cell.label.stringValue = stat.label
            cell.value.stringValue = stat.value
            cell.value.toolTip = stat.value
            cell.value.setAccessibilityIdentifier(stat.identifier ?? "performance.stat.value")
            cell.value.setAccessibilityLabel(stat.accessibilityLabel ?? "\(stat.label), \(stat.value)")
        }
        if structureChanged {
            rebuildGrid(columns: columnCount(for: bounds.width))
        }
    }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }
        let desired = columnCount(for: bounds.width)
        if desired != columns { rebuildGrid(columns: desired) }
        applyColumnWidths()
    }

    /// Fixes each column to an equal share of the width, so the grid never grows past the card.
    private func applyColumnWidths() {
        guard let grid = gridView, columns > 0, bounds.width > 0 else { return }
        let spacing = grid.columnSpacing * CGFloat(columns - 1)
        let width = floor((bounds.width - spacing) / CGFloat(columns))
        for index in 0..<columns {
            grid.column(at: index).width = width
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        if width >= 560 { return 3 }
        if width >= 320 { return 2 }
        return 1
    }

    private func rebuildGrid(columns count: Int) {
        gridView?.removeFromSuperview()
        gridView = nil
        columns = count
        guard !cells.isEmpty, count > 0 else { return }

        let rowCount = (cells.count + count - 1) / count
        let grid = NSGridView(numberOfColumns: count, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        for row in 0..<rowCount {
            var views: [NSView] = []
            for column in 0..<count {
                let index = row * count + column
                views.append(index < cells.count ? cells[index] : NSView())
            }
            grid.addRow(with: views)
        }
        for column in 0..<count {
            grid.column(at: column).xPlacement = .fill
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        gridView = grid
        applyColumnWidths()
    }
}

/// One stat: a caption above a single-line value. Frame-based, so the value is clipped to the cell width.
@MainActor
private final class MetricStatCellView: NSView {
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.autoresizingMask = [.width]
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        value.textColor = .labelColor
        value.lineBreakMode = .byTruncatingTail
        value.usesSingleLineMode = true
        value.autoresizingMask = [.width]
        addSubview(label)
        addSubview(value)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 15)
        value.frame = NSRect(x: 0, y: 16, width: bounds.width, height: 18)
    }
}

/// Plain flipped container so the scroll view starts at the top of the card.
@MainActor
private final class PerformanceFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Rounded card with the same fill and stroke as the other cards in the app.
@MainActor
private final class PerformanceCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
