import AppKit

/// One plotted line. A secondary series is a lighter tint of the metric hue and is never filled.
struct MetricGraphSeries {
    let name: String
    let color: NSColor
    let readings: [MetricReading]
    let isSecondary: Bool

    init(name: String, color: NSColor, readings: [MetricReading], isSecondary: Bool = false) {
        self.name = name
        self.color = color
        self.readings = readings
        self.isSecondary = isSecondary
    }
}

/// Tooltip owner for gap markers. AppKit calls it outside the view's actor context;
/// it has no stored state and always returns the same string.
private final class GapToolTipOwner: NSObject, NSViewToolTipOwner, @unchecked Sendable {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        MetricGraphView.sampleGapToolTip
    }
}

private let gapToolTipOwner = GapToolTipOwner()

/// Line graph for one or more series over time, with a 1.5 pt line, a gradient fill, and axis labels in `.detail` style.
///
/// Readings are placed by timestamp (`.time`) or by slot (`.index`). Unavailable readings break the line and are
/// never drawn as zero. A `.sleepGap` reading also gets a dotted marker and a "Sample gap" tooltip.
@MainActor
final class MetricGraphView: NSView {
    enum Style {
        /// Rounded background, grid at 25, 50 and 75 percent, and axis labels.
        case detail
        /// Rounded background with a midline. Used for per-processor tiles.
        case compact
        /// No chrome. Used for rail and swap sparklines.
        case sparkline
    }

    enum XMapping: Equatable {
        /// Seconds covered by the plot width, ending at the newest reading.
        case time(TimeInterval)
        /// The newest reading sits at the right edge of `capacity` slots.
        case index(capacity: Int)
    }

    /// Tooltip for a sleep-gap marker. Nothing is said about pausing: a gap can come from sleep or from a missed sample.
    nonisolated static let sampleGapToolTip = String(localized: "Sample gap")

    let style: Style
    private(set) var series: [MetricGraphSeries] = []
    private var fixedMaximum: Double?
    private var mapping: XMapping = .time(60)
    private var topLabel: String?
    private var spanLabel: String?
    /// Cursor x in view coordinates while the pointer is over the plot. Nil when not hovering or for `.sparkline`.
    private(set) var hoverX: CGFloat?
    private var hoverArea: NSTrackingArea?

    private struct Trace {
        let series: MetricGraphSeries
        var segments: [[NSPoint]] = []
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    /// Replaces the plotted series. `maximum` nil scales to the largest visible value.
    func update(series: [MetricGraphSeries], maximum: Double? = nil, mapping: XMapping,
                topLabel: String? = nil, spanLabel: String? = nil) {
        self.series = series
        fixedMaximum = maximum
        self.mapping = mapping
        self.topLabel = topLabel
        self.spanLabel = spanLabel
        refreshGapToolTips()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshGapToolTips()
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect()
        guard plot.width > 1, plot.height > 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        if style != .sparkline {
            let clip = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.06).setFill()
            clip.fill()
            clip.addClip()
        }
        drawGrid(in: plot)
        let maximum = effectiveMaximum()
        let result = traces(in: plot, maximum: maximum)
        drawFills(result.traces, in: plot)
        drawLines(result.traces)
        drawGapMarkers(result.gaps, in: plot)
        NSGraphicsContext.restoreGraphicsState()

        if style == .detail { drawAxisLabels(in: plot) }
        // Last, so the readout box sits above the axis labels.
        drawHover(in: plot, maximum: maximum)
    }

    // MARK: Geometry

    private func plotRect() -> NSRect {
        switch style {
        case .detail:
            let gutter = max(30, ceil(labelWidth(topLabel)) + 8)
            return NSRect(x: bounds.minX + gutter, y: bounds.minY + 22,
                          width: bounds.width - gutter - 12, height: bounds.height - 44)
        case .compact:
            return bounds.insetBy(dx: 5, dy: 6)
        case .sparkline:
            return bounds.insetBy(dx: 1, dy: 3)
        }
    }

    private func xPosition(index: Int, count: Int, timestamp: Date, end: Date, plot: NSRect) -> CGFloat? {
        switch mapping {
        case .time(let span):
            guard span > 0 else { return nil }
            let age = end.timeIntervalSince(timestamp)
            guard age >= 0, age <= span else { return nil }
            return plot.maxX - CGFloat(age / span) * plot.width
        case .index(let capacity):
            let age = count - 1 - index
            guard age >= 0, age < capacity else { return nil }
            return plot.maxX - CGFloat(age) / CGFloat(max(capacity - 1, 1)) * plot.width
        }
    }

    private func effectiveMaximum() -> Double {
        if let fixedMaximum, fixedMaximum.isFinite, fixedMaximum > 0 { return fixedMaximum }
        let values = series.flatMap(\.readings).compactMap(\.value).filter { $0.isFinite && $0 >= 0 }
        return max(values.max() ?? 1, 0.0001)
    }

    private func traces(in plot: NSRect, maximum: Double) -> (traces: [Trace], gaps: [CGFloat]) {
        guard let end = series.compactMap({ $0.readings.last?.timestamp }).max() else { return ([], []) }
        var traces: [Trace] = []
        var gaps: [CGFloat] = []
        for item in series {
            var trace = Trace(series: item)
            var current: [NSPoint] = []
            let count = item.readings.count
            for (index, reading) in item.readings.enumerated() {
                guard let x = xPosition(index: index, count: count, timestamp: reading.timestamp, end: end, plot: plot) else {
                    if !current.isEmpty { trace.segments.append(current); current = [] }
                    continue
                }
                if reading.unavailableReason == .sleepGap { gaps.append(x) }
                guard let value = reading.value, value.isFinite, value >= 0 else {
                    if !current.isEmpty { trace.segments.append(current); current = [] }
                    continue
                }
                let fraction = min(max(value / maximum, 0), 1)
                current.append(NSPoint(x: x, y: plot.minY + plot.height * CGFloat(fraction)))
            }
            if !current.isEmpty { trace.segments.append(current) }
            traces.append(trace)
        }
        return (traces, gaps)
    }

    private func uniqueGapPositions(_ gaps: [CGFloat]) -> [CGFloat] {
        Array(Set(gaps.map { ($0 * 2).rounded() / 2 })).sorted()
    }

    // MARK: Drawing

    private func drawGrid(in plot: NSRect) {
        let fractions: [CGFloat]
        switch style {
        case .detail: fractions = [0.25, 0.5, 0.75]
        case .compact: fractions = [0.5]
        case .sparkline: return
        }
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for fraction in fractions {
            let y = plot.minY + plot.height * fraction
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        NSColor.separatorColor.withAlphaComponent(highContrast ? 0.7 : 0.35).setStroke()
        grid.stroke()
    }

    private func drawFills(_ traces: [Trace], in plot: NSRect) {
        guard let primary = traces.first(where: { !$0.series.isSecondary }) else { return }
        let color = primary.series.color
        guard let gradient = NSGradient(starting: color.withAlphaComponent(0.02),
                                        ending: color.withAlphaComponent(0.25)) else { return }
        for segment in primary.segments where segment.count > 1 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: segment[0].x, y: plot.minY))
            for point in segment { path.line(to: point) }
            path.line(to: NSPoint(x: segment[segment.count - 1].x, y: plot.minY))
            path.close()
            gradient.draw(in: path, angle: 90)
        }
    }

    private func drawLines(_ traces: [Trace]) {
        let width = lineWidth()
        // Secondary series first so the primary line sits on top.
        let ordered = traces.filter { $0.series.isSecondary } + traces.filter { !$0.series.isSecondary }
        for trace in ordered {
            let color = Self.lineColor(for: trace.series, highContrast: highContrast)
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            for segment in trace.segments {
                if segment.count == 1 {
                    let point = segment[0]
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: point.x - width, y: point.y - width,
                                                width: width * 2, height: width * 2)).fill()
                } else if segment.count > 1 {
                    path.move(to: segment[0])
                    for point in segment.dropFirst() { path.line(to: point) }
                }
            }
            color.setStroke()
            path.stroke()
        }
    }

    private func drawGapMarkers(_ gaps: [CGFloat], in plot: NSRect) {
        let positions = uniqueGapPositions(gaps)
        guard !positions.isEmpty else { return }
        let markers = NSBezierPath()
        markers.lineWidth = 1
        markers.setLineDash([2, 3], count: 2, phase: 0)
        for x in positions {
            markers.move(to: NSPoint(x: x, y: plot.minY))
            markers.line(to: NSPoint(x: x, y: plot.maxY))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(highContrast ? 1.0 : 0.7).setStroke()
        markers.stroke()
    }

    private func drawAxisLabels(in plot: NSRect) {
        if let topLabel { drawLabel(topLabel, anchor: NSPoint(x: plot.minX - 6, y: plot.maxY), alignRight: true) }
        drawLabel("0", anchor: NSPoint(x: plot.minX - 6, y: plot.minY), alignRight: true)
        if let spanLabel { drawLabel(spanLabel, anchor: NSPoint(x: plot.minX, y: plot.minY - 18), alignRight: false) }
        drawLabel("0", anchor: NSPoint(x: plot.maxX, y: plot.minY - 18), alignRight: true)
    }

    private func drawLabel(_ text: String, anchor: NSPoint, alignRight: Bool) {
        let size = (text as NSString).size(withAttributes: Self.labelAttributes)
        let origin = NSPoint(x: alignRight ? anchor.x - size.width : anchor.x, y: anchor.y - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: Self.labelAttributes)
    }

    private func labelWidth(_ text: String?) -> CGFloat {
        guard let text else { return 0 }
        return (text as NSString).size(withAttributes: Self.labelAttributes).width
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.tertiaryLabelColor
    ]

    /// Increase Contrast: thicker lines, stronger secondary series, grid and gap markers.
    private var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private func lineWidth() -> CGFloat {
        switch style {
        case .detail: return highContrast ? 2.5 : 1.5
        case .compact: return highContrast ? 2.0 : 1.2
        case .sparkline: return highContrast ? 2.0 : 1.25
        }
    }

    /// Stroke for a series: the metric hue for the primary line, a lighter tint for the secondary one.
    /// The legend uses the same color, so a swatch always matches its line.
    static func lineColor(for series: MetricGraphSeries, highContrast: Bool) -> NSColor {
        series.isSecondary ? series.color.withAlphaComponent(highContrast ? 0.9 : 0.55) : series.color
    }

    // MARK: Gap tooltips

    private func refreshGapToolTips() {
        removeAllToolTips()
        // While the readout is showing, gap tooltips would fight it; they come back when the pointer leaves.
        guard hoverX == nil else { return }
        let plot = plotRect()
        guard plot.width > 1, plot.height > 1 else { return }
        let gaps = traces(in: plot, maximum: effectiveMaximum()).gaps
        for x in uniqueGapPositions(gaps) {
            addToolTip(NSRect(x: x - 4, y: plot.minY, width: 8, height: plot.height),
                       owner: gapToolTipOwner, userData: nil)
        }
    }

    // MARK: Hover inspection

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard style != .sparkline else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(x: nil)
    }

    private func updateHover(with event: NSEvent) {
        setHover(x: convert(event.locationInWindow, from: nil).x)
    }

    /// Sets the cursor x for the readout. Values outside the plot's horizontal span clear it. Redraws only on change.
    func setHover(x: CGFloat?) {
        guard style != .sparkline else { return }
        let plot = plotRect()
        let next = x.flatMap { $0 >= plot.minX && $0 <= plot.maxX ? $0 : nil }
        guard next != hoverX else { return }
        let wasHovering = hoverX != nil
        hoverX = next
        if wasHovering != (next != nil) { refreshGapToolTips() }
        needsDisplay = true
    }

    /// The sample nearest the cursor: its index in the reference series (the one with the most readings) and the x it is drawn at.
    private func hoveredSample(in plot: NSRect) -> (index: Int, x: CGFloat)? {
        guard let hoverX, let end = series.compactMap({ $0.readings.last?.timestamp }).max(),
              let reference = series.max(by: { $0.readings.count < $1.readings.count }) else { return nil }
        let count = reference.readings.count
        var positions: [(index: Int, x: CGFloat)] = []
        for (index, reading) in reference.readings.enumerated() {
            if let x = xPosition(index: index, count: count, timestamp: reading.timestamp, end: end, plot: plot) {
                positions.append((index, x))
            }
        }
        guard let nearest = Self.nearestIndex(toX: hoverX, in: positions.map(\.x)) else { return nil }
        return positions[nearest]
    }

    /// Vertical rule, a dot per series at the sampled value, and the readout box. Drawn only while hovering.
    private func drawHover(in plot: NSRect, maximum: Double) {
        guard let hovered = hoveredSample(in: plot) else { return }
        let x = hovered.x

        let rule = NSBezierPath()
        rule.lineWidth = 1
        rule.move(to: NSPoint(x: x, y: plot.minY))
        rule.line(to: NSPoint(x: x, y: plot.maxY))
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        rule.stroke()

        let referenceCount = series.map { $0.readings.count }.max() ?? 0
        for item in series {
            // An unavailable sample gets no dot: it is never drawn as zero.
            guard let reading = Self.sample(in: item, atReference: hovered.index, referenceCount: referenceCount),
                  let value = reading.value, value.isFinite, value >= 0 else { continue }
            let y = plot.minY + plot.height * CGFloat(min(max(value / maximum, 0), 1))
            Self.lineColor(for: item, highContrast: highContrast).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
        }

        drawReadout(Self.readoutLines(series: series, index: hovered.index), pointingAt: x, plot: plot)
    }

    private func drawReadout(_ lines: [String], pointingAt x: CGFloat, plot: NSRect) {
        guard !lines.isEmpty else { return }
        let padding = Self.readoutPadding
        let texts = lines.enumerated().map { index, line in
            NSAttributedString(string: line, attributes: index == 0 ? Self.readoutTitleAttributes : Self.readoutBodyAttributes)
        }
        let sizes = texts.map { $0.size() }
        let contentWidth = sizes.map { ceil($0.width) }.max() ?? 0
        let contentHeight = sizes.reduce(CGFloat(0)) { $0 + ceil($1.height) }
        let boxSize = NSSize(width: contentWidth + padding * 2, height: contentHeight + padding * 2)

        // Sit right of the cursor; flip to the left when that would run past the right edge. Keep it inside bounds.
        var originX = x + 10
        if originX + boxSize.width > bounds.maxX { originX = x - 10 - boxSize.width }
        originX = min(max(originX, bounds.minX + 2), bounds.maxX - boxSize.width - 2)
        let originY = max(plot.maxY - boxSize.height, bounds.minY + 2)
        let rect = NSRect(origin: NSPoint(x: originX, y: originY), size: boxSize)

        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()

        var top = rect.maxY - padding
        for (text, size) in zip(texts, sizes) {
            let height = ceil(size.height)
            text.draw(at: NSPoint(x: rect.minX + padding, y: top - height))
            top -= height
        }
    }

    private static let readoutPadding: CGFloat = 8
    private static let readoutTitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.labelColor
    ]
    private static let readoutBodyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    /// Text for the hover readout: the sample time first, then one line per series as "<name>  <value>".
    /// `index` is a sample index in the reference series; shorter series line up with the newest samples.
    /// Unavailable readings show their reason, sleep gaps show "Sample gap", and nothing is shown as zero.
    static func readoutLines(series: [MetricGraphSeries], index: Int) -> [String] {
        let referenceCount = series.map { $0.readings.count }.max() ?? 0
        guard index >= 0, index < referenceCount else { return [] }
        let samples = series.map { sample(in: $0, atReference: index, referenceCount: referenceCount) }
        guard let timestamp = samples.compactMap({ $0?.timestamp }).first else { return [] }
        var lines = [UIFormat.time(timestamp)]
        for (item, sample) in zip(series, samples) {
            let text = sample.map(readoutValue) ?? UIFormat.unavailable(.notCollected)
            lines.append("\(item.name)  \(text)")
        }
        return lines
    }

    private static func readoutValue(_ reading: MetricReading) -> String {
        if reading.unavailableReason == .sleepGap { return sampleGapToolTip }
        return UIFormat.metric(reading)
    }

    /// The reading of `series` that lines up with `index` in the reference series. Alignment is by the newest sample.
    private static func sample(in series: MetricGraphSeries, atReference index: Int, referenceCount: Int) -> MetricReading? {
        let own = index - (referenceCount - series.readings.count)
        guard series.readings.indices.contains(own) else { return nil }
        return series.readings[own]
    }

    /// Index of the x position nearest to `x`; the earlier position wins a tie. Nil for no positions or a non-finite `x`.
    static func nearestIndex(toX x: CGFloat, in xs: [CGFloat]) -> Int? {
        guard x.isFinite else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, candidate) in xs.enumerated() where candidate.isFinite {
            let distance = abs(candidate - x)
            if let current = best, current.distance <= distance { continue }
            best = (index, distance)
        }
        return best?.index
    }
}

/// Thin timeline of memory pressure: one colored run per sample, with dotted gap markers.
/// Unavailable samples leave the track empty, so they never read as normal pressure.
@MainActor
final class MemoryPressureStripView: NSView {
    private var samples: [MemoryPressureSample] = []
    private var span: TimeInterval = 60

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    func update(samples: [MemoryPressureSample], span: TimeInterval) {
        self.samples = samples
        self.span = max(span, 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.quaternarySystemFill.setFill()
        track.fill()
        guard let end = samples.last?.timestamp else { return }

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var gapXs: [CGFloat] = []
        for (index, sample) in samples.enumerated() {
            let start = xPosition(sample.timestamp, end: end)
            if sample.isGap { gapXs.append(start) }
            guard let level = sample.level else { continue }
            let stop = index + 1 < samples.count ? xPosition(samples[index + 1].timestamp, end: end) : bounds.maxX
            guard stop > start else { continue }
            color(for: level).setFill()
            NSRect(x: start, y: bounds.minY, width: stop - start, height: bounds.height).fill()
        }
        if !gapXs.isEmpty {
            let markers = NSBezierPath()
            markers.lineWidth = 1
            markers.setLineDash([1.5, 2], count: 2, phase: 0)
            for x in gapXs {
                markers.move(to: NSPoint(x: x, y: bounds.minY))
                markers.line(to: NSPoint(x: x, y: bounds.maxY))
            }
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            markers.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func xPosition(_ timestamp: Date, end: Date) -> CGFloat {
        let fraction = min(max(end.timeIntervalSince(timestamp) / span, 0), 1)
        return bounds.maxX - CGFloat(fraction) * bounds.width
    }

    private func color(for level: MemoryPressureLevel) -> NSColor {
        switch level {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// Used/total capacity bar. A nil fraction draws only the empty track.
@MainActor
final class CapacityBarView: NSView {
    private var fraction: Double?
    private let tint: NSColor

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    func setFraction(_ value: Double?) {
        fraction = value.map { min(max($0, 0), 1) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.quaternarySystemFill.setFill()
        track.fill()
        guard let fraction, fraction > 0 else { return }
        var filled = bounds
        filled.size.width = bounds.width * CGFloat(fraction)
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        tint.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
