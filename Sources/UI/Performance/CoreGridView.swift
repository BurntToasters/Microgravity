import AppKit

/// Per-logical-processor mini graphs in a grid of 4 to 6 per row, chosen from the available width.
///
/// Every tile uses the same single hue. Color only separates series inside one graph, so cores past eight
/// never cycle through a palette.
@MainActor
final class CoreGridView: NSView {
    private static let tileHeight: CGFloat = 76
    private static let gap: CGFloat = 10
    private static let minimumTileWidth: CGFloat = 110

    private var tiles: [CoreTile] = []
    private var tileConstraints: [NSLayoutConstraint] = []
    private var laidOutColumns = 0
    private var laidOutWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Grouped so the grid and its identifier are reachable as one element; the tiles carry their own identifiers.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("CPU utilization by logical processor")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: gridHeight(columns: columns(for: bounds.width)))
    }

    func update(cores: [CoreTileModel], mapping: MetricGraphView.XMapping) {
        if tiles.count != cores.count {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = cores.map { _ in CoreTile() }
            for tile in tiles {
                tile.translatesAutoresizingMaskIntoConstraints = false
                addSubview(tile)
            }
            laidOutColumns = 0
            laidOutWidth = -1
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        for (tile, core) in zip(tiles, cores) {
            tile.configure(core, mapping: mapping)
        }
    }

    override func layout() {
        super.layout()
        let count = columns(for: bounds.width)
        guard count != laidOutColumns || bounds.width != laidOutWidth else { return }
        laidOutColumns = count
        laidOutWidth = bounds.width
        // Tile geometry is constrained explicitly, so no autoresizing constraints from a zero frame can conflict.
        NSLayoutConstraint.deactivate(tileConstraints)
        let tileWidth = max(0, (bounds.width - Self.gap * CGFloat(count - 1)) / CGFloat(count))
        var constraints: [NSLayoutConstraint] = []
        for (index, tile) in tiles.enumerated() {
            let column = CGFloat(index % count)
            let row = CGFloat(index / count)
            constraints += [
                tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: column * (tileWidth + Self.gap)),
                tile.topAnchor.constraint(equalTo: topAnchor, constant: row * (Self.tileHeight + Self.gap)),
                tile.widthAnchor.constraint(equalToConstant: tileWidth),
                tile.heightAnchor.constraint(equalToConstant: Self.tileHeight)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        tileConstraints = constraints
        invalidateIntrinsicContentSize()
    }

    /// Four to six columns, never more columns than tiles.
    func columns(for width: CGFloat) -> Int {
        let fitting = Int((width + Self.gap) / (Self.minimumTileWidth + Self.gap))
        return max(1, min(max(fitting, 4), 6, tiles.count))
    }

    private func gridHeight(columns: Int) -> CGFloat {
        guard !tiles.isEmpty, columns > 0 else { return 0 }
        let rows = (tiles.count + columns - 1) / columns
        return CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.gap
    }
}

/// One processor: "CPU n" with its current value above a compact graph.
@MainActor
private final class CoreTile: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let graph = MetricGraphView(style: .compact)

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [titleLabel, valueLabel, graph] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor),
            graph.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ core: CoreTileModel, mapping: MetricGraphView.XMapping) {
        titleLabel.stringValue = "CPU \(core.index)"
        valueLabel.stringValue = core.valueText
        graph.setAccessibilityIdentifier("performance.cpu-core.\(core.index)")
        graph.setAccessibilityLabel("CPU \(core.index), \(core.valueText)")
        graph.update(series: [core.series], maximum: 100, mapping: mapping)
    }
}
