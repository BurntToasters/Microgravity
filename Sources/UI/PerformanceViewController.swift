import AppKit

@MainActor
final class PerformanceViewController: NSViewController, SnapshotUpdating {
    private let dependencies: PageDependencies
    private let cpuGraph = MetricGraphView()
    private let diskGraph = MetricGraphView()
    private let networkGraph = MetricGraphView()
    private let gpuGraph = MetricGraphView()
    private let energyGraph = MetricGraphView()
    private let coreGraph = MetricGraphView()
    private let memoryPressureGraph = MetricGraphView()
    private let swapGraph = MetricGraphView()
    private let pauseButton = NSButton(title: "Pause Sampling", target: nil, action: nil)
    private let cpuValue = NSTextField(labelWithString: "—")
    private let memoryState = NSTextField(labelWithString: "Waiting for sample")
    private let memoryValue = NSTextField(labelWithString: "—")
    private let swapValue = NSTextField(labelWithString: "—")
    private let gpuState = NSTextField(labelWithString: "Waiting for sample")
    private let energyTitle = UIComponents.label("Energy", size: 13, weight: .semibold)
    private let energyDefinition = UIComponents.label("Energy or power is shown in the source unit supplied by its provider.", size: 10, color: .secondaryLabelColor)
    private let energyState = NSTextField(labelWithString: "Waiting for sample")
    private let freshness = NSTextField(labelWithString: "Waiting for the first sample")
    private let coreStack = NSStackView()
    private var snapshot: MonitoringSnapshot?

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Performance",
            subtitle: "Live resource use. Graphs retain sample gaps and distinguish missing data from zero."
        )
        freshness.font = .systemFont(ofSize: 11)
        freshness.textColor = .secondaryLabelColor
        freshness.setAccessibilityIdentifier("performance.sampling-state")
        let headerRow = NSStackView(views: [header, NSView(), freshness])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        pauseButton.target = self
        pauseButton.action = #selector(toggleSampling)
        pauseButton.setAccessibilityIdentifier("performance.action.pause")
        pauseButton.bezelStyle = .rounded

        cpuGraph.setAccessibilityIdentifier("performance.graph.cpu-total")
        cpuGraph.setAccessibilityLabel("Total CPU usage percentage over time")
        diskGraph.setAccessibilityIdentifier("performance.graph.disk")
        networkGraph.setAccessibilityIdentifier("performance.graph.network")
        gpuGraph.setAccessibilityIdentifier("performance.graph.gpu")
        energyGraph.setAccessibilityIdentifier("performance.graph.energy")
        coreGraph.setAccessibilityIdentifier("performance.graph.cpu-cores")
        memoryPressureGraph.setAccessibilityIdentifier("performance.memory-pressure.graph")
        swapGraph.setAccessibilityIdentifier("performance.swap.graph")

        cpuValue.font = .systemFont(ofSize: 22, weight: .semibold)
        cpuValue.setAccessibilityIdentifier("performance.cpu-total.value")
        memoryValue.font = .systemFont(ofSize: 18, weight: .medium)
        memoryValue.setAccessibilityIdentifier("performance.memory.value")
        memoryState.font = .systemFont(ofSize: 12, weight: .medium)
        memoryState.setAccessibilityIdentifier("performance.memory-pressure.state")
        swapValue.setAccessibilityIdentifier("performance.swap.value")
        gpuState.setAccessibilityIdentifier("performance.gpu.state")
        energyState.setAccessibilityIdentifier("performance.energy.state")

        let cpuPanel = makeGraphPanel(title: "CPU", subtitle: "Total logical-core utilization · percent", graph: cpuGraph,
                                      value: cpuValue, definition: "CPU time used across logical cores, normalized to total system capacity (0–100%).")
        let corePanel = makeCorePanel()
        let memoryPanel = makeMemoryPanel()
        let swapPanel = makeSwapPanel()
        let diskPanel = makeGraphPanel(title: "Disk throughput", subtitle: "Read and write · bytes per second", graph: diskGraph,
                                       value: nil, definition: "Measured device read and write throughput.")
        let networkPanel = makeGraphPanel(title: "Network throughput", subtitle: "Received and sent · bytes per second", graph: networkGraph,
                                          value: nil, definition: "Measured interface bytes received and sent per second.")
        let gpuPanel = makeGraphPanel(title: "GPU activity", subtitle: "Provider-reported unit", graph: gpuGraph,
                                      value: gpuState, definition: "GPU activity is shown only when a provider reports it.")
        let energyPanel = makeGraphPanel(title: "Energy", subtitle: "Provider-reported unit", graph: energyGraph,
                                         value: energyState, definition: "", titleLabel: energyTitle, definitionLabel: energyDefinition)

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.distribution = .fill
        grid.spacing = 14
        grid.addArrangedSubview(makeRow(cpuPanel, corePanel))
        grid.addArrangedSubview(makeRow(memoryPanel, swapPanel))
        grid.addArrangedSubview(makeRow(diskPanel, networkPanel))
        grid.addArrangedSubview(makeRow(gpuPanel, energyPanel))
        grid.translatesAutoresizingMaskIntoConstraints = false
        for row in grid.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        let content = NSStackView(views: [headerRow, pauseButton, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.widthAnchor.constraint(equalTo: content.widthAnchor),
            headerRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        self.snapshot = snapshot
        let samples = dependencies.monitoringStore.graphSamples
        cpuValue.stringValue = UIFormat.metric(snapshot.system.cpuPercent)
        freshness.stringValue = dependencies.monitoringStore.isPaused
            ? "Paused · last sample \(UIFormat.time(snapshot.timestamp))"
            : "Updated \(UIFormat.time(snapshot.timestamp))"

        cpuGraph.update(series: [MetricGraphSeries(name: "CPU", color: .systemBlue,
                                                  readings: samples.map(\.cpuPercent))], maximum: 100)
        let coreCount = samples.map(\.perCoreCPUPercent.count).max() ?? 0
        let coreColors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple,
                                    .systemPink, .systemTeal, .systemIndigo, .systemBrown]
        let coreSeries = (0..<coreCount).map { index in
            MetricGraphSeries(name: "Core \(index)", color: coreColors[index % coreColors.count],
                              readings: samples.map { sample in
                                  sample.perCoreCPUPercent.indices.contains(index)
                                    ? sample.perCoreCPUPercent[index]
                                    : MetricReading(unavailable: .percent, timestamp: sample.timestamp, reason: .notCollected)
                              })
        }
        coreGraph.update(series: coreSeries, maximum: 100)
        diskGraph.update(series: [
            MetricGraphSeries(name: "Read", color: .systemBlue, readings: samples.map(\.diskReadBytesPerSecond)),
            MetricGraphSeries(name: "Write", color: .systemOrange, readings: samples.map(\.diskWriteBytesPerSecond))
        ])
        networkGraph.update(series: [
            MetricGraphSeries(name: "Receive", color: .systemBlue, readings: samples.map(\.networkReceiveBytesPerSecond)),
            MetricGraphSeries(name: "Send", color: .systemOrange, readings: samples.map(\.networkTransmitBytesPerSecond))
        ])
        updateCoreActivity(snapshot.system.perCoreCPUPercent)
        updateMemory(snapshot)
        updateSwap(snapshot)
        let pressureReadings = samples.map { sample -> MetricReading in
            guard let level = sample.memoryPressure.level else {
                return MetricReading(unavailable: .count, timestamp: sample.timestamp,
                                     reason: sample.memoryPressure.unavailableReason ?? .notCollected)
            }
            let value: Double
            switch level {
            case .normal: value = 0
            case .warning: value = 1
            case .critical: value = 2
            }
            return MetricReading(value: value, unit: .count, timestamp: sample.timestamp)
        }
        memoryPressureGraph.update(series: [MetricGraphSeries(name: "Pressure", color: .systemGreen,
                                                               readings: pressureReadings)], maximum: 2)
        swapGraph.update(series: [
            MetricGraphSeries(name: "Used", color: .systemOrange, readings: samples.map(\.swapUsedBytes)),
            MetricGraphSeries(name: "Total", color: .systemBlue, readings: samples.map(\.swapTotalBytes))
        ])
        updateAdvancedMetric(.gpu, snapshot: snapshot, graph: gpuGraph, state: gpuState, defaultUnit: .percent)
        let isComponentPower = snapshot.advancedMetrics[.energy]?.unit == .watts && snapshot.advancedMetrics[.energy]?.value != nil
        energyTitle.stringValue = isComponentPower ? "Estimated component power" : "Energy"
        energyDefinition.stringValue = isComponentPower
            ? "Estimated CPU + GPU + ANE component power; not total device power."
            : "Energy or power is shown in the source unit supplied by its provider."
        updateAdvancedMetric(.energy, snapshot: snapshot, graph: energyGraph, state: energyState, defaultUnit: .joules)
        pauseButton.title = dependencies.monitoringStore.isPaused ? "Resume Sampling" : "Pause Sampling"
    }

    private func makeRow(_ left: NSView, _ right: NSView) -> NSView {
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        left.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        right.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true
        return row
    }

    private func makeGraphPanel(title: String, subtitle: String, graph: MetricGraphView,
                                value: NSTextField?, definition: String,
                                titleLabel: NSTextField? = nil, definitionLabel: NSTextField? = nil) -> NSView {
        let details = NSStackView()
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        details.addArrangedSubview(definitionLabel ?? UIComponents.label(definition, size: 10, color: .secondaryLabelColor))
        if let value { details.addArrangedSubview(value) }
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 64).isActive = true
        graph.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        details.addArrangedSubview(graph)
        return UIComponents.card(title: title, subtitle: subtitle, titleLabel: titleLabel, content: details)
    }

    private func makeCorePanel() -> NSView {
        coreStack.orientation = .vertical
        coreStack.alignment = .leading
        coreStack.spacing = 6
        let definition = UIComponents.label("Current utilization for each logical core.", size: 10, color: .secondaryLabelColor)
        coreGraph.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let container = NSStackView(views: [definition, coreStack, coreGraph])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        return UIComponents.card(title: "Per-core CPU", subtitle: "Percent · current sample", content: container)
    }

    private func makeMemoryPanel() -> NSView {
        memoryPressureGraph.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let details = NSStackView(views: [memoryValue, memoryState, memoryPressureGraph,
                                          UIComponents.label("Kernel memory pressure: normal, warning, or critical.", size: 10, color: .secondaryLabelColor)])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        return UIComponents.card(title: "Memory", subtitle: "Used / total · pressure", identifier: "performance.graph.memory-pressure", content: details)
    }

    private func makeSwapPanel() -> NSView {
        swapGraph.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let details = NSStackView(views: [swapValue, swapGraph,
                                          UIComponents.label("Virtual memory currently in use / configured total.", size: 10, color: .secondaryLabelColor)])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        return UIComponents.card(title: "Swap", subtitle: "Used / total · bytes", identifier: "performance.graph.swap", content: details)
    }

    private func updateCoreActivity(_ readings: [MetricReading]) {
        guard !readings.isEmpty else {
            if coreStack.arrangedSubviews.count == 1,
               let placeholder = coreStack.arrangedSubviews.first as? NSTextField {
                placeholder.stringValue = "Unavailable · per-core data not collected"
                return
            }
            clearCoreActivityRows()
            coreStack.addArrangedSubview(UIComponents.label("Unavailable · per-core data not collected", size: 11, color: .secondaryLabelColor))
            return
        }

        if coreStack.arrangedSubviews.count == readings.count,
           coreStack.arrangedSubviews.allSatisfy({ $0 is NSStackView }) {
            for (index, reading) in readings.enumerated() {
                guard let row = coreStack.arrangedSubviews[index] as? NSStackView,
                      row.arrangedSubviews.count == 3,
                      let meter = row.arrangedSubviews[1] as? NSProgressIndicator,
                      let text = row.arrangedSubviews[2] as? NSTextField else { continue }
                meter.doubleValue = min(max(reading.value ?? 0, 0), 100)
                text.stringValue = UIFormat.metric(reading)
            }
            return
        }

        clearCoreActivityRows()
        for (index, reading) in readings.enumerated() {
            let label = UIComponents.label("Core \(index)", size: 10, color: .secondaryLabelColor)
            label.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let meter = NSProgressIndicator()
            meter.isIndeterminate = false
            meter.minValue = 0
            meter.maxValue = 100
            meter.doubleValue = min(max(reading.value ?? 0, 0), 100)
            meter.style = .bar
            meter.controlSize = .small
            meter.setAccessibilityIdentifier("performance.cpu-core.\(index)")
            let text = UIComponents.label(UIFormat.metric(reading), size: 10, color: .secondaryLabelColor)
            text.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let row = NSStackView(views: [label, meter, text])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
            coreStack.addArrangedSubview(row)
        }
    }

    private func clearCoreActivityRows() {
        coreStack.arrangedSubviews.forEach { coreStack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func updateMemory(_ snapshot: MonitoringSnapshot) {
        memoryValue.stringValue = "\(UIFormat.metric(snapshot.system.memoryUsedBytes)) / \(UIFormat.metric(snapshot.system.memoryTotalBytes))"
        switch snapshot.system.memoryPressure.level {
        case .normal: memoryState.stringValue = "Normal memory pressure"
        case .warning: memoryState.stringValue = "Warning · memory pressure elevated"
        case .critical: memoryState.stringValue = "Critical memory pressure"
        case nil:
            memoryState.stringValue = UIFormat.unavailable(snapshot.system.memoryPressure.unavailableReason)
        }
        memoryState.textColor = snapshot.system.memoryPressure.level == .critical ? .systemRed : .secondaryLabelColor
    }

    private func updateSwap(_ snapshot: MonitoringSnapshot) {
        swapValue.stringValue = "\(UIFormat.metric(snapshot.system.swapUsedBytes)) / \(UIFormat.metric(snapshot.system.swapTotalBytes))"
    }

    private func updateAdvancedMetric(_ kind: MetricKind, snapshot: MonitoringSnapshot,
                                      graph: MetricGraphView, state: NSTextField, defaultUnit: MetricUnit) {
        let reading = snapshot.advancedMetrics[kind]
        let availability = snapshot.capabilities[kind]
        let samples = dependencies.monitoringStore.graphSamples
        let graphReadings = samples.map { sample in
            sample.advancedMetrics[kind] ?? MetricReading(
                unavailable: reading?.unit ?? defaultUnit,
                timestamp: sample.timestamp,
                reason: snapshot.capabilities[kind]?.reason ?? .notCollected,
                detail: snapshot.capabilities[kind]?.detail
            )
        }
        let unit = reading?.unit ?? graphReadings.last?.unit ?? defaultUnit
        let current = reading ?? MetricReading(unavailable: unit, timestamp: snapshot.timestamp,
                                                reason: availability?.reason ?? .warmingUp,
                                                detail: availability?.detail)
        if current.value != nil {
            state.stringValue = UIFormat.metric(current)
        } else if let availability, !availability.available {
            state.stringValue = UIFormat.availability(availability)
        } else {
            state.stringValue = UIFormat.metric(current)
        }
        graph.update(series: [MetricGraphSeries(name: kind.rawValue.capitalized, color: .systemPurple,
                                                readings: graphReadings)],
                     maximum: kind == .gpu ? 100 : nil)
    }

    @objc private func toggleSampling() {
        if dependencies.monitoringStore.isPaused {
            dependencies.monitoringStore.resume()
        } else {
            dependencies.monitoringStore.pause()
        }
        if let snapshot { update(snapshot: snapshot) }
    }
}

private struct MetricGraphSeries {
    let name: String
    let color: NSColor
    let readings: [MetricReading]
}

@MainActor
private final class MetricGraphView: NSView {
    private var series: [MetricGraphSeries] = []
    private var fixedMaximum: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        needsDisplay = true
    }

    func update(series input: [MetricGraphSeries], maximum: Double? = nil) {
        series = input
        fixedMaximum = maximum
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = bounds.insetBy(dx: 8, dy: 7)
        guard plot.width > 0, plot.height > 0 else { return }
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        for fraction in [0.25, 0.5, 0.75] {
            let y = plot.minY + plot.height * fraction
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }
        let allValues = series.flatMap(\.readings).compactMap(\.value).filter { $0.isFinite && $0 >= 0 }
        guard !allValues.isEmpty else { return }
        let maximum = max(fixedMaximum ?? allValues.max() ?? 1, 0.0001)
        for item in series {
            draw(item.readings, color: item.color, in: plot, maximum: maximum)
        }
    }

    private func draw(_ readings: [MetricReading], color: NSColor, in plot: NSRect, maximum: Double) {
        guard !readings.isEmpty else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var active = false
        let denominator = max(readings.count - 1, 1)
        for (index, reading) in readings.enumerated() {
            guard let value = reading.value, value.isFinite, value >= 0 else {
                active = false
                continue
            }
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(denominator)
            let normalized = min(max(value / maximum, 0), 1)
            let y = plot.minY + plot.height * CGFloat(normalized)
            let point = NSPoint(x: x, y: y)
            if active { path.line(to: point) } else { path.move(to: point) }
            active = true
        }
        color.setStroke()
        path.stroke()
    }
}
