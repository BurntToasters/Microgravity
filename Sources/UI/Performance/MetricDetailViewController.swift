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
    private let hardwareSpecLabel = NSTextField(labelWithString: "")
    private let bigValueLabel = NSTextField(labelWithString: "")
    private let cpuModeControl = NSSegmentedControl(labels: [String(localized: "Overall"), String(localized: "Logical Processors")],
                                                    trackingMode: .selectOne, target: nil, action: nil)
    private let windowPicker = NSSegmentedControl(labels: PerformanceWindow.allCases.map(\.title),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "")
    private let energyChipsRow = NSStackView()
    private let powerSourceChip = StateChipView()
    private let thermalStateChip = StateChipView()
    private let banner = StatusBannerView(style: .info)
    private let graph = MetricGraphView(style: .detail)
    private let coreGrid = CoreGridView()
    private let legendRow = NSStackView()
    private var legendNames: [String]?
    private var legendSwatches: [LegendSwatchView] = []
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let statsGrid = MetricStatsGridView()
    private let interfaceSection = NSStackView()
    private var interfaceRowNames: [String]?
    private var interfaceRowViews: [InterfaceRowView] = []
    private var lastInterfaceRows: [NetworkInterfaceRow] = []
    private var showingVirtualInterfaces = false
    private let virtualToggleButton = NSButton(title: "", target: nil, action: nil)
    private let memorySection = NSStackView()
    private let memoryColumns = NSStackView()
    private let memoryCompositionBar = MemoryCompositionBarView()
    private let pressureBlock = NSStackView()
    private let pressureChip = StateChipView()
    private let pressureStrip = MemoryPressureStripView()
    private let swapBlock = NSStackView()
    private let swapValueLabel = NSTextField(labelWithString: "")
    private let swapBar = CapacityBarView(tint: ColorPreferences.color(for: .memory))
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
        hardwareSpecLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hardwareSpecLabel.textColor = .tertiaryLabelColor
        hardwareSpecLabel.lineBreakMode = .byTruncatingTail
        hardwareSpecLabel.maximumNumberOfLines = 1
        hardwareSpecLabel.setAccessibilityIdentifier("performance.detail.hardware-spec")
        bigValueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        bigValueLabel.textColor = .labelColor
        bigValueLabel.alignment = .right
        bigValueLabel.lineBreakMode = .byTruncatingTail
        // Secondary header text must give way before the card does: at narrow widths the card keeps its width and long text truncates.
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for field in [subtitleLabel, hardwareSpecLabel, bigValueLabel] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        cpuModeControl.segmentStyle = .rounded
        cpuModeControl.target = self
        cpuModeControl.action = #selector(cpuModePicked(_:))
        cpuModeControl.setAccessibilityIdentifier("performance.cpu.mode")
        cpuModeControl.setAccessibilityLabel(String(localized: "CPU view"))
        windowPicker.segmentStyle = .rounded
        windowPicker.target = self
        windowPicker.action = #selector(windowPicked(_:))
        windowPicker.setAccessibilityIdentifier("performance.window")
        windowPicker.setAccessibilityLabel(String(localized: "Graph time window"))

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .labelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.maximumNumberOfLines = 0
        captionLabel.preferredMaxLayoutWidth = 0
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, Self.spacer(), bigValueLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let subtitleStack = NSStackView(views: [subtitleLabel, hardwareSpecLabel])
        subtitleStack.orientation = .vertical
        subtitleStack.alignment = .leading
        subtitleStack.spacing = 2
        let subtitleRow = NSStackView(views: [subtitleStack, Self.spacer(), windowPicker])
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .centerY
        subtitleRow.spacing = 8
        let controls = NSStackView(views: [cpuModeControl, Self.spacer()])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        energyChipsRow.orientation = .horizontal
        energyChipsRow.alignment = .centerY
        energyChipsRow.spacing = 8
        powerSourceChip.label.setAccessibilityIdentifier("performance.energy.source")
        thermalStateChip.label.setAccessibilityIdentifier("performance.energy.thermal")
        energyChipsRow.addArrangedSubview(powerSourceChip)
        energyChipsRow.addArrangedSubview(thermalStateChip)
        energyChipsRow.isHidden = true

        virtualToggleButton.bezelStyle = .inline
        virtualToggleButton.target = self
        virtualToggleButton.action = #selector(toggleVirtualInterfaces(_:))
        virtualToggleButton.setAccessibilityIdentifier("performance.network.toggle-virtual")

        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 240).isActive = true
        graph.setAccessibilityElement(true)
        coreGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The grid's height is exactly its tile rows, so the stack must neither stretch nor squeeze it: a squeezed
        // grid would clip or overlap its last row of tiles and the caption below.
        coreGrid.setContentHuggingPriority(.required, for: .vertical)
        coreGrid.setContentCompressionResistancePriority(.required, for: .vertical)
        coreGrid.setAccessibilityIdentifier("performance.graph.cpu-cores")
        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        legendRow.spacing = 14
        legendRow.setAccessibilityIdentifier("performance.legend")

        buildPressureBlock()
        buildSwapBlock()
        memoryColumns.orientation = .horizontal
        memoryColumns.alignment = .top
        memoryColumns.distribution = .fillEqually
        memoryColumns.spacing = 16
        memoryColumns.addArrangedSubview(pressureBlock)
        memoryColumns.addArrangedSubview(swapBlock)

        memorySection.orientation = .vertical
        memorySection.alignment = .leading
        memorySection.spacing = 12
        Self.addFullWidth(memoryCompositionBar, to: memorySection)
        Self.addFullWidth(memoryColumns, to: memorySection)

        interfaceSection.orientation = .vertical
        interfaceSection.alignment = .leading
        interfaceSection.spacing = 6
        let interfaceTitle = Self.sectionTitle(String(localized: "Interfaces"))
        interfaceSection.addArrangedSubview(interfaceTitle)
        Self.fillWidth(interfaceTitle, in: interfaceSection)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for item in [header, subtitleRow, controls, stateLabel, energyChipsRow, banner, graph, legendRow,
                     coreGrid, captionLabel, statsGrid, interfaceSection, memorySection] as [NSView] {
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
        titleLabel.setAccessibilityLabel(model.title)
        subtitleLabel.stringValue = model.subtitle
        subtitleLabel.setAccessibilityLabel(model.subtitle)
        hardwareSpecLabel.isHidden = model.hardwareSpecText == nil
        hardwareSpecLabel.stringValue = model.hardwareSpecText ?? ""
        hardwareSpecLabel.setAccessibilityLabel(model.hardwareSpecText ?? "")
        bigValueLabel.stringValue = model.bigValue
        bigValueLabel.setAccessibilityLabel(model.bigValue)
        bigValueLabel.textColor = model.isBigValueUnavailable ? .secondaryLabelColor : .labelColor
        bigValueLabel.setAccessibilityIdentifier(model.bigValueIdentifier ?? "performance.detail.value")

        windowPicker.selectedSegment = PerformanceWindow.allCases.firstIndex(of: model.window) ?? 0
        cpuModeControl.isHidden = model.metric != .cpu
        cpuModeControl.selectedSegment = model.cpuMode.rawValue

        stateLabel.isHidden = model.stateText == nil
        stateLabel.stringValue = model.stateText ?? ""
        stateLabel.setAccessibilityIdentifier(model.stateIdentifier ?? "performance.detail.state")
        stateLabel.setAccessibilityLabel(model.stateText ?? "")
        if let energy = model.energy {
            energyChipsRow.isHidden = false
            if let sourceText = energy.powerSourceText {
                powerSourceChip.isHidden = false
                powerSourceChip.setState(text: sourceText, tint: energy.powerSourceTint)
            } else {
                powerSourceChip.isHidden = true
            }
            thermalStateChip.setState(text: energy.thermalStateText, tint: energy.thermalStateTint)
        } else {
            energyChipsRow.isHidden = true
        }
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
        updateLegend(model.series)

        coreGrid.isHidden = !showsCores
        if showsCores {
            coreGrid.update(sections: model.coreSections, mapping: .time(model.timeSpan))
        }

        captionLabel.isHidden = model.caption == nil
        captionLabel.stringValue = model.caption ?? ""
        captionLabel.setAccessibilityIdentifier(model.captionIdentifier ?? "performance.detail.caption")
        captionLabel.setAccessibilityLabel(model.captionAccessibilityLabel ?? model.caption ?? "")

        statsGrid.update(model.stats)

        interfaceSection.isHidden = model.metric != .network
        if model.metric == .network { updateInterfaces(model.interfaces) }

        memorySection.isHidden = model.memory == nil
        memoryCompositionBar.update(model.memoryComposition)
        refreshSwapBarTint()
        if let memory = model.memory { updateMemory(memory, timeSpan: model.timeSpan) }
    }

    // MARK: Sections

    /// Updates the swap bar's tint in place when the memory color changes, preserving its view and accessibility identity.
    private func refreshSwapBarTint() {
        swapBar.setTint(ColorPreferences.color(for: .memory))
    }

    private func buildPressureBlock() {
        pressureBlock.orientation = .vertical
        pressureBlock.alignment = .leading
        pressureBlock.spacing = 6
        pressureBlock.setAccessibilityElement(true)
        pressureBlock.setAccessibilityRole(.group)
        pressureBlock.setAccessibilityLabel(String(localized: "Memory pressure"))
        pressureBlock.setAccessibilityIdentifier("performance.graph.memory-pressure")
        pressureChip.label.setAccessibilityIdentifier("performance.memory-pressure.state")
        pressureStrip.setAccessibilityIdentifier("performance.memory-pressure.graph")
        let title = Self.sectionTitle(String(localized: "Memory pressure"))
        let caption = NSTextField(wrappingLabelWithString: String(localized: "Normal, warning, and critical samples over the graph window."))
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 0
        caption.preferredMaxLayoutWidth = 0
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
        swapBlock.setAccessibilityLabel(String(localized: "Swap"))
        swapBlock.setAccessibilityIdentifier("performance.graph.swap")
        swapValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        swapValueLabel.textColor = .labelColor
        swapValueLabel.lineBreakMode = .byTruncatingTail
        swapValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        swapValueLabel.setAccessibilityIdentifier("performance.swap.value")
        swapGraph.setAccessibilityIdentifier("performance.swap.graph")
        swapGraph.setAccessibilityLabel(String(localized: "Swap used over time"))
        swapBar.setAccessibilityLabel(String(localized: "Swap used against total"))
        swapBlock.addArrangedSubview(Self.sectionTitle(String(localized: "Swap")))
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
        pressureStrip.setAccessibilityLabel(String(localized: "Memory pressure history, \(memory.pressureText)"))

        swapValueLabel.stringValue = memory.swapValue
        swapValueLabel.setAccessibilityLabel(memory.swapValue)
        swapBar.setFraction(memory.swapFraction)
        swapBar.setAccessibilityValue(memory.swapValue)
        swapGraph.update(series: memory.swapSeries.map { [$0] } ?? [], maximum: memory.swapMaximum,
                         mapping: .time(timeSpan))
    }

    /// Legend entries are rebuilt only when the series names change. Swatch colors are refreshed in place.
    private func updateLegend(_ series: [MetricGraphSeries]) {
        legendRow.isHidden = series.count <= 1
        let names = series.map(\.name)
        if names != legendNames {
            legendNames = names
            for view in legendRow.arrangedSubviews {
                legendRow.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            legendSwatches = []
            for item in series {
                let swatch = LegendSwatchView()
                let label = NSTextField(labelWithString: item.name)
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let entry = NSStackView(views: [swatch, label])
                entry.orientation = .horizontal
                entry.alignment = .centerY
                entry.spacing = 5
                legendSwatches.append(swatch)
                legendRow.addView(entry, in: .leading)
            }
        }
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for (swatch, item) in zip(legendSwatches, series) {
            swatch.setColor(MetricGraphView.lineColor(for: item, highContrast: highContrast))
        }
    }

    /// Interface rows are reused while the interface list keeps its order; only their text changes each sample,
    /// so the section does not rebuild its views (and VoiceOver keeps its place) on every refresh.
    private func updateInterfaces(_ rows: [NetworkInterfaceRow]) {
        lastInterfaceRows = rows
        let primaryRows = rows.filter(\.includedInTotals)
        let virtualRows = rows.filter { !$0.includedInTotals }
        let displayed = primaryRows.isEmpty ? rows : (showingVirtualInterfaces ? rows : primaryRows)
        let showDisclosure = !primaryRows.isEmpty && !virtualRows.isEmpty
        let names = displayed.map(\.name) + (showDisclosure ? ["__virtual_toggle_\(virtualRows.count)_\(showingVirtualInterfaces)"] : [])
        if names == interfaceRowNames, interfaceRowViews.count == displayed.count {
            for (view, row) in zip(interfaceRowViews, displayed) { view.apply(row) }
            return
        }
        for view in interfaceSection.arrangedSubviews.dropFirst() {
            interfaceSection.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        interfaceRowNames = names
        interfaceRowViews = []
        if rows.isEmpty {
            let empty = Self.caption(String(localized: "No network interfaces reported."))
            interfaceSection.addArrangedSubview(empty)
            Self.fillWidth(empty, in: interfaceSection)
            return
        }
        for row in primaryRows.isEmpty ? rows : primaryRows {
            let view = InterfaceRowView()
            view.apply(row)
            interfaceSection.addArrangedSubview(view)
            Self.fillWidth(view, in: interfaceSection)
            interfaceRowViews.append(view)
        }
        if showDisclosure {
            virtualToggleButton.title = showingVirtualInterfaces
                ? String(localized: "Hide \(virtualRows.count) virtual interfaces")
                : String(localized: "Show \(virtualRows.count) virtual interfaces")
            interfaceSection.addArrangedSubview(virtualToggleButton)
            if showingVirtualInterfaces {
                for row in virtualRows {
                    let view = InterfaceRowView()
                    view.apply(row)
                    interfaceSection.addArrangedSubview(view)
                    Self.fillWidth(view, in: interfaceSection)
                    interfaceRowViews.append(view)
                }
            }
        }
    }

    @objc private func toggleVirtualInterfaces(_ sender: Any?) {
        showingVirtualInterfaces.toggle()
        interfaceRowNames = nil
        updateInterfaces(lastInterfaceRows)
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

/// 8 pt rounded swatch for the graph legend, filled with the same color as the matching line.
@MainActor
private final class LegendSwatchView: NSView {
    private var color: NSColor = .clear

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func setColor(_ color: NSColor) {
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
        label.setAccessibilityLabel(text)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Stats as label-over-value cells laid out directly by frame in 1 to 3 columns.
///
/// Using direct frame placement avoids adding/removing `NSGridView` hierarchies and Auto Layout constraints during
/// `layout()`, preventing AppKit layout recursion while keeping every cell fixed at its column width.
@MainActor
private final class MetricStatsGridView: NSView {
    private static let cellHeight: CGFloat = 34
    private static let rowSpacing: CGFloat = 12
    private static let columnSpacing: CGFloat = 16

    private var keys: [String] = []
    private var cells: [MetricStatCellView] = []
    private var laidOutColumns = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let cols = columnCount(for: bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(columns: cols))
    }

    func update(_ stats: [MetricStat]) {
        let newKeys = stats.map(\.label)
        if newKeys != keys {
            for cell in cells {
                cell.removeFromSuperview()
            }
            keys = newKeys
            cells = stats.map { _ in
                let cell = MetricStatCellView()
                cell.translatesAutoresizingMaskIntoConstraints = true
                cell.frame = NSRect(x: 0, y: 0, width: 140, height: Self.cellHeight)
                addSubview(cell)
                return cell
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        for (cell, stat) in zip(cells, stats) {
            cell.label.stringValue = stat.label
            cell.value.stringValue = stat.value
            cell.value.toolTip = stat.value
            cell.value.setAccessibilityIdentifier(stat.identifier ?? "performance.stat.value")
            cell.value.setAccessibilityLabel(stat.accessibilityLabel ?? "\(stat.label), \(stat.value)")
        }
    }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }
        let count = columnCount(for: bounds.width)
        if count != laidOutColumns {
            laidOutColumns = count
            if window == nil {
                invalidateIntrinsicContentSize()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.invalidateIntrinsicContentSize()
                }
            }
        }
        let width = bounds.width
        let colWidth = max(0, (width - Self.columnSpacing * CGFloat(count - 1)) / CGFloat(count))
        for (index, cell) in cells.enumerated() {
            let col = index % count
            let row = index / count
            let frame = NSRect(
                x: CGFloat(col) * (colWidth + Self.columnSpacing),
                y: CGFloat(row) * (Self.cellHeight + Self.rowSpacing),
                width: colWidth,
                height: Self.cellHeight
            )
            if cell.frame != frame {
                cell.frame = frame
            }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        if width >= 560 { return 3 }
        if width >= 320 { return 2 }
        return 1
    }

    private func contentHeight(columns count: Int) -> CGFloat {
        guard !cells.isEmpty, count > 0 else { return 0 }
        let rowCount = (cells.count + count - 1) / count
        return CGFloat(rowCount) * Self.cellHeight + CGFloat(rowCount - 1) * Self.rowSpacing
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

/// One network interface: name and membership on the left, rates and totals on the right.
@MainActor
private final class InterfaceRowView: NSStackView {
    private let name = NSTextField(labelWithString: "")
    private let membership = NSTextField(labelWithString: "")
    private let rates = NSTextField(labelWithString: "")
    private let totals = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .labelColor
        rates.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rates.textColor = .labelColor
        rates.alignment = .right
        for caption in [membership, totals] {
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
        }
        totals.alignment = .right
        for label in [name, membership, rates, totals] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let left = NSStackView(views: [name, membership])
        left.orientation = .vertical
        left.alignment = .width
        left.spacing = 2
        let right = NSStackView(views: [rates, totals])
        right.orientation = .vertical
        right.alignment = .width
        right.spacing = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setViews([left, spacer, right], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        for view in [left, right, self] as [NSView] {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ row: NetworkInterfaceRow) {
        name.stringValue = row.name
        membership.stringValue = row.membership
        rates.stringValue = row.rates
        totals.stringValue = row.totals
        setAccessibilityLabel("\(row.name), \(row.rates), \(row.totals), \(row.membership)")
        setAccessibilityIdentifier("performance.network.interface.\(row.name)")
    }
}
