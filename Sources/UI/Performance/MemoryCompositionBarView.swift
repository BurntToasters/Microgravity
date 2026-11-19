import AppKit

struct MemoryCompositionSegment: Equatable {
    let title: String
    let bytes: Double
    let color: NSColor
    let formattedBytes: String
}

struct MemoryCompositionModel: Equatable {
    let totalBytes: Double
    let segments: [MemoryCompositionSegment]
}

/// Horizontal segmented bar showing App, Wired, Compressed, Cached, and Free physical memory.
@MainActor
final class MemoryCompositionBarView: NSView {
    private let stack = NSStackView()
    private let barView = SegmentedBarCanvas()
    private let legendFlow = MemoryLegendFlowView()
    private var lastModel: MemoryCompositionModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityIdentifier("performance.memory.composition")
        setAccessibilityRole(.group)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let title = NSTextField(labelWithString: String(localized: "Memory composition"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(barView)
        stack.addArrangedSubview(legendFlow)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            barView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barView.heightAnchor.constraint(equalToConstant: 12),
            legendFlow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ model: MemoryCompositionModel?) {
        guard let model, model.totalBytes > 0, !model.segments.isEmpty else {
            isHidden = true
            lastModel = nil
            return
        }
        isHidden = false
        guard model != lastModel else { return }
        lastModel = model

        barView.update(totalBytes: model.totalBytes, segments: model.segments)
        legendFlow.update(segments: model.segments)

        let summary = model.segments.map { "\($0.title) \($0.formattedBytes)" }.joined(separator: ", ")
        setAccessibilityLabel(String(localized: "Memory composition: \(summary)"))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        barView.needsDisplay = true
    }
}

@MainActor
private final class MemoryLegendFlowView: NSView {
    private static let itemHeight: CGFloat = 14
    private static let horizontalSpacing: CGFloat = 12
    private static let verticalSpacing: CGFloat = 4

    private var items: [NSView] = []
    private var laidOutHeight: CGFloat = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let height = computeHeight(forWidth: bounds.width > 0 ? bounds.width : 600)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func update(segments: [MemoryCompositionSegment]) {
        for item in items {
            item.removeFromSuperview()
        }
        items = segments.map { segment in
            let dot = LegendSwatchDotView(color: segment.color)
            let label = NSTextField(labelWithString: "\(segment.title) \(segment.formattedBytes)")
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail

            let item = NSStackView(views: [dot, label])
            item.orientation = .horizontal
            item.alignment = .centerY
            item.spacing = 4
            item.translatesAutoresizingMaskIntoConstraints = true
            let fit = item.fittingSize
            item.frame = NSRect(x: 0, y: 0, width: ceil(fit.width), height: Self.itemHeight)
            addSubview(item)
            return item
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !items.isEmpty else { return }
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        for item in items {
            let itemWidth = min(max(ceil(item.fittingSize.width), 20), max(maxWidth, 20))
            if x > 0 && x + itemWidth > maxWidth {
                x = 0
                y += Self.itemHeight + Self.verticalSpacing
            }
            let frame = NSRect(x: x, y: y, width: itemWidth, height: Self.itemHeight)
            if item.frame != frame {
                item.frame = frame
            }
            x += itemWidth + Self.horizontalSpacing
        }
        let totalHeight = y + Self.itemHeight
        if abs(totalHeight - laidOutHeight) > 0.5 {
            laidOutHeight = totalHeight
            if window == nil {
                invalidateIntrinsicContentSize()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.invalidateIntrinsicContentSize()
                }
            }
        }
    }

    private func computeHeight(forWidth maxWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        var x: CGFloat = 0
        var rows = 1
        for item in items {
            let itemWidth = min(max(ceil(item.fittingSize.width), 20), max(maxWidth, 20))
            if x > 0 && x + itemWidth > maxWidth {
                x = 0
                rows += 1
            }
            x += itemWidth + Self.horizontalSpacing
        }
        return CGFloat(rows) * Self.itemHeight + CGFloat(rows - 1) * Self.verticalSpacing
    }
}

@MainActor
private final class LegendSwatchDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.cgColor
    }
}

@MainActor
private final class SegmentedBarCanvas: NSView {
    private var totalBytes: Double = 0
    private var segments: [MemoryCompositionSegment] = []

    func update(totalBytes: Double, segments: [MemoryCompositionSegment]) {
        self.totalBytes = totalBytes
        self.segments = segments
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        clipPath.addClip()
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard totalBytes > 0, bounds.width > 0 else { return }
        let drawn = segments.filter { $0.bytes > 0 && CGFloat($0.bytes / totalBytes) * bounds.width >= 1 }
        guard !drawn.isEmpty else { return }
        let gap: CGFloat = 1
        let totalGap = CGFloat(max(0, drawn.count - 1)) * gap
        let drawableWidth = max(0, bounds.width - totalGap)
        var x: CGFloat = 0
        for (index, segment) in drawn.enumerated() {
            let width = min(bounds.maxX - x, CGFloat(segment.bytes / totalBytes) * drawableWidth)
            guard width > 0 else { continue }
            segment.color.setFill()
            NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
            x += width
            if index + 1 < drawn.count { x += gap }
        }
    }
}
