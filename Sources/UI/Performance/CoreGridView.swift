import AppKit

/// Per-logical-processor mini graphs in a grid of 4 to 6 per row, chosen from the available width.
///
/// Tiles can be grouped into sections, one per processor class. A titled section draws a header above its tiles;
/// an untitled section draws none. Each tile uses its section's hue. Color only separates sections or series, so
/// cores past eight never cycle through a palette.
@MainActor
final class CoreGridView: NSView {
    private static let tileHeight: CGFloat = 76
    private static let gap: CGFloat = 10
    private static let minimumTileWidth: CGFloat = 110
    private static let headerHeight: CGFloat = 16
    private static let headerSpacing: CGFloat = 6
    private static let sectionSpacing: CGFloat = 14

    /// Views for one section. The header exists only for a titled section.
    private struct SectionViews {
        let header: CoreSectionHeaderView?
        let tiles: [CoreTile]
    }

    /// The structure that decides when views are rebuilt. Titles and colors change in place.
    private struct SectionShape: Equatable {
        let titled: Bool
        let tileCount: Int
    }

    private var sections: [SectionViews] = []
    private var shape: [SectionShape] = []
    /// Column count from the last layout pass. The intrinsic height changes only when this changes.
    private var laidOutColumns = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Grouped so the grid and its identifier are reachable as one element; the tiles carry their own identifiers.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "CPU utilization by logical processor"))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(columns: columns(for: bounds.width)))
    }

    /// One ungrouped list of tiles, with no header.
    func update(cores: [CoreTileModel], mapping: MetricGraphView.XMapping) {
        update(sections: [CoreSectionModel(title: nil, slug: nil, color: PerformanceMetric.cpu.color, cores: cores)],
               mapping: mapping)
    }

    func update(sections models: [CoreSectionModel], mapping: MetricGraphView.XMapping) {
        let newShape = models.map { SectionShape(titled: $0.title != nil, tileCount: $0.cores.count) }
        if newShape != shape {
            for section in sections {
                section.header?.removeFromSuperview()
                section.tiles.forEach { $0.removeFromSuperview() }
            }
            shape = newShape
            sections = models.map { model in
                let header = model.title == nil ? nil : CoreSectionHeaderView()
                if let header {
                    header.translatesAutoresizingMaskIntoConstraints = true
                    addSubview(header)
                }
                // Tiles are positioned by frame in layout(), so they keep autoresizing masks and get no position constraints.
                // A tile's own constraints need a real size, so it starts at a nominal frame rather than zero until layout().
                let tiles = model.cores.map { _ in CoreTile() }
                for tile in tiles {
                    tile.translatesAutoresizingMaskIntoConstraints = true
                    tile.frame = NSRect(x: 0, y: 0, width: Self.minimumTileWidth, height: Self.tileHeight)
                    addSubview(tile)
                }
                return SectionViews(header: header, tiles: tiles)
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        for (section, model) in zip(sections, models) {
            if let header = section.header, let title = model.title, let slug = model.slug {
                header.configure(title: title, color: model.color, identifier: "performance.cpu-cores.section.\(slug)")
            }
            for (tile, core) in zip(section.tiles, model.cores) {
                tile.configure(core, mapping: mapping)
            }
        }
    }

    /// Places every header and tile from the current bounds on every pass. No constraints are involved, so a width
    /// change, a hidden-to-shown transition, or a new section set cannot leave a view at a stale or arbitrary frame.
    override func layout() {
        super.layout()
        let count = columns(for: bounds.width)
        if count != laidOutColumns {
            laidOutColumns = count
            invalidateIntrinsicContentSize()
        }
        let width = bounds.width
        let tileWidth = max(0, (width - Self.gap * CGFloat(count - 1)) / CGFloat(count))
        var top: CGFloat = 0
        for section in sections {
            if let header = section.header {
                setFrame(of: header, to: NSRect(x: 0, y: top, width: width, height: Self.headerHeight))
                top += Self.headerHeight + Self.headerSpacing
            }
            for (index, tile) in section.tiles.enumerated() {
                let frame = NSRect(x: CGFloat(index % count) * (tileWidth + Self.gap),
                                   y: top + CGFloat(index / count) * (Self.tileHeight + Self.gap),
                                   width: tileWidth, height: Self.tileHeight)
                setFrame(of: tile, to: frame)
            }
            top += rowsHeight(tileCount: section.tiles.count, columns: count) + Self.sectionSpacing
        }
    }

    /// Four to six columns, never more columns than tiles across all sections.
    func columns(for width: CGFloat) -> Int {
        let fitting = Int((width + Self.gap) / (Self.minimumTileWidth + Self.gap))
        return max(1, min(max(fitting, 4), 6, totalTileCount))
    }

    private var totalTileCount: Int {
        sections.reduce(0) { $0 + $1.tiles.count }
    }

    /// Headers, tile rows and the gaps between sections. `layout()` uses the same arithmetic.
    private func contentHeight(columns: Int) -> CGFloat {
        var height: CGFloat = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { height += Self.sectionSpacing }
            if section.header != nil { height += Self.headerHeight + Self.headerSpacing }
            height += rowsHeight(tileCount: section.tiles.count, columns: columns)
        }
        return height
    }

    private func rowsHeight(tileCount: Int, columns: Int) -> CGFloat {
        guard tileCount > 0, columns > 0 else { return 0 }
        let rows = (tileCount + columns - 1) / columns
        return CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.gap
    }

    private func setFrame(of view: NSView, to frame: NSRect) {
        if view.frame != frame {
            view.frame = frame
        }
    }
}

/// Section title: a 8 pt rounded color swatch, then the title in 12 pt semibold secondary text.
/// Frame-based like the grid, so the title truncates to the width instead of pushing the grid wider.
@MainActor
private final class CoreSectionHeaderView: NSView {
    private static let swatchSize: CGFloat = 8
    private static let swatchGap: CGFloat = 6

    private let swatch = CoreSwatchView()
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(swatch)
        addSubview(titleLabel)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = Self.swatchSize
        swatch.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
        let x = size + Self.swatchGap
        titleLabel.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height)
    }

    func configure(title: String, color: NSColor, identifier: String) {
        titleLabel.stringValue = title
        titleLabel.setAccessibilityIdentifier(identifier)
        swatch.setColor(color)
    }
}

/// Solid rounded square for a section's color. Decorative, so it is hidden from accessibility.
@MainActor
private final class CoreSwatchView: NSView {
    private var color: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        titleLabel.stringValue = String(localized: "CPU \(core.index)")
        valueLabel.stringValue = core.valueText
        let description = Self.description(core)
        graph.setAccessibilityIdentifier("performance.cpu-core.\(core.index)")
        graph.setAccessibilityLabel(description)
        toolTip = description
        graph.update(series: [core.series], maximum: 100, mapping: mapping)
    }

    /// "CPU 12, Super core, 19.8%" when the processor class is known, otherwise "CPU 12, 19.8%".
    private static func description(_ core: CoreTileModel) -> String {
        guard let kind = core.kindName else {
            return String(localized: "CPU \(core.index), \(core.valueText)")
        }
        return String(localized: "CPU \(core.index), \(kind) core, \(core.valueText)")
    }
}
