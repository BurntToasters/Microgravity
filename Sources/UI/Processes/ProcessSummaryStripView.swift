import AppKit

/// Compact clickable live-totals bar above the Processes table, inspired by Task Manager headers.
final class ProcessSummaryStripView: NSView {
    var onSelectMetric: ((PerformanceMetric) -> Void)?

    private struct Tile {
        let metric: PerformanceMetric
        let button: NSButton
        let dotView: NSView
        let titleLabel: NSTextField
        let valueLabel: NSTextField
    }

    private let stackView = NSStackView()
    private var tiles: [PerformanceMetric: Tile] = [:]
    private let orderedMetrics: [PerformanceMetric] = [.cpu, .memory, .disk, .network]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        configureView()
        NotificationCenter.default.addObserver(self, selector: #selector(colorPreferencesChanged),
                                               name: .colorPreferencesDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func colorPreferencesChanged() {
        applyColors()
    }

    func update(snapshot: MonitoringSnapshot?) {
        applyColors()
        guard let system = snapshot?.system else {
            for metric in orderedMetrics {
                tiles[metric]?.valueLabel.stringValue = "—"
            }
            return
        }

        let cpuText = UIFormat.value(system.cpuPercent) ?? "—"

        let memoryText: String
        if let used = system.memoryUsedBytes.value, let pct = Self.memoryPercent(used: used, total: system.memoryTotalBytes.value) {
            memoryText = "\(pct)% · \(UIFormat.bytes(used))"
        } else {
            memoryText = UIFormat.value(system.memoryUsedBytes) ?? "—"
        }

        let diskText: String
        if system.diskReadBytesPerSecond.value != nil || system.diskWriteBytesPerSecond.value != nil {
            let combined = (system.diskReadBytesPerSecond.value ?? 0) + (system.diskWriteBytesPerSecond.value ?? 0)
            diskText = combined.isFinite ? UIFormat.bytesPerSecond(combined) : "—"
        } else {
            diskText = "—"
        }

        let networkText: String
        if system.networkReceiveBytesPerSecond.value != nil || system.networkTransmitBytesPerSecond.value != nil {
            let combined = (system.networkReceiveBytesPerSecond.value ?? 0)
                + (system.networkTransmitBytesPerSecond.value ?? 0)
            networkText = combined.isFinite ? UIFormat.bytesPerSecond(combined) : "—"
        } else {
            networkText = "—"
        }

        set(metric: .cpu, value: cpuText)
        set(metric: .memory, value: memoryText)
        set(metric: .disk, value: diskText)
        set(metric: .network, value: networkText)
    }

    /// Whole-number percent of memory in use, clamped to 0...100. Nil when either reading is non-finite or the total is not positive.
    static func memoryPercent(used: Double, total: Double?) -> Int? {
        guard let total, used.isFinite, total.isFinite, total > 0 else { return nil }
        let ratio = ((used / total) * 100).rounded()
        guard ratio.isFinite else { return nil }
        return Int(min(max(ratio, 0), 100))
    }

    private func set(metric: PerformanceMetric, value: String) {
        guard let tile = tiles[metric] else { return }
        tile.valueLabel.stringValue = value
        tile.button.setAccessibilityLabel("\(metric.title): \(value)")
    }

    private func configureView() {
        setAccessibilityElement(false)
        setAccessibilityIdentifier("processes.summary-strip")

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 8
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 46)
        ])

        for (index, metric) in orderedMetrics.enumerated() {
            let tile = makeTile(metric: metric, tag: index)
            tiles[metric] = tile
            stackView.addArrangedSubview(tile.button)
        }
        applyColors()
    }

    private func makeTile(metric: PerformanceMetric, tag: Int) -> Tile {
        let button = NSButton(title: "", target: self, action: #selector(handleTileClick(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.tag = tag
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.setButtonType(.momentaryChange)
        button.setAccessibilityIdentifier("processes.summary.\(metric.rawValue)")
        button.toolTip = String(localized: "Show \(metric.title) in Performance")

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4

        let title = NSTextField(labelWithString: metric.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail

        let value = NSTextField(labelWithString: "—")
        value.translatesAutoresizingMaskIntoConstraints = false
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        value.textColor = .labelColor
        value.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [dot, title])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 5

        let contentStack = NSStackView(views: [topRow, value])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 1

        button.addSubview(contentStack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            contentStack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -10),
            contentStack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        return Tile(metric: metric, button: button, dotView: dot, titleLabel: title, valueLabel: value)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (metric, tile) in tiles {
                tile.dotView.layer?.backgroundColor = metric.color.cgColor
                tile.button.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
                tile.button.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            }
        }
    }

    @objc private func handleTileClick(_ sender: NSButton) {
        guard orderedMetrics.indices.contains(sender.tag) else { return }
        onSelectMetric?(orderedMetrics[sender.tag])
    }
}
