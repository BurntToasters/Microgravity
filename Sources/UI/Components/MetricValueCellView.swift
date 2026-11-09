import AppKit

/// Numeric table cell: right-aligned monospaced-digit value, optional trailing badge, and a heat fill.
///
/// Configure it with `configure(presentation:heatIntensity:heatColor:alignment:accessibilityIdentifier:)`.
/// The heat fill is a 4 pt rounded rect inset from the cell edges (not the whole cell), drawn in the
/// caller's column color with an alpha ramp, and is suppressed on selected rows. The text field carries
/// the accessibility identifier.
@MainActor
final class MetricValueCellView: NSTableCellView {
    private let valueField = NSTextField(labelWithString: "")
    private let badgeView = NSImageView()
    private let stack = NSStackView()
    private var heatIntensity: Double?
    private var heatColor: NSColor = .systemOrange

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeView.imageScaling = .scaleProportionallyDown
        badgeView.setAccessibilityElement(false)
        badgeView.setContentHuggingPriority(.required, for: .horizontal)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.isHidden = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.distribution = .fill
        stack.addArrangedSubview(valueField)
        stack.addArrangedSubview(badgeView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 13),
            badgeView.heightAnchor.constraint(equalToConstant: 13),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = valueField
    }

    required init?(coder: NSCoder) { nil }

    /// Heat alpha for a 0...1 intensity: 0 below 1%, otherwise `0.32 * intensity^0.6`.
    /// With Increase Contrast on, alpha is multiplied by 1.6 and capped at 0.6.
    static func heatAlpha(intensity: Double, increaseContrast: Bool) -> CGFloat {
        guard intensity.isFinite, intensity >= 0.01 else { return 0 }
        let clamped = min(intensity, 1)
        let base = 0.32 * pow(clamped, 0.6)
        return CGFloat(increaseContrast ? min(base * 1.6, 0.6) : base)
    }

    /// Updates the value, badge, tooltip, accessibility, alignment and heat for this cell.
    /// - Parameters:
    ///   - heatIntensity: Value as a fraction of the column maximum (or physical memory / 100%), 0...1. Nil draws no heat.
    ///   - heatColor: Hue of the heat fill; each process column passes its own color.
    ///   - accessibilityIdentifier: Set on the value text field.
    func configure(presentation: MetricCellPresentation, heatIntensity: Double?,
                   heatColor: NSColor = .systemOrange,
                   alignment: NSTextAlignment = .right, accessibilityIdentifier: String? = nil) {
        valueField.stringValue = presentation.valueText
        valueField.alignment = alignment
        valueField.toolTip = presentation.toolTip
        toolTip = presentation.toolTip
        valueField.setAccessibilityLabel(presentation.accessibilityDescription)
        if let accessibilityIdentifier {
            valueField.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        if let symbol = presentation.badge.symbolName {
            badgeView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            badgeView.contentTintColor = presentation.badge == .partial ? .systemOrange : .secondaryLabelColor
            badgeView.isHidden = false
        } else {
            badgeView.image = nil
            badgeView.isHidden = true
        }
        self.heatIntensity = heatIntensity
        self.heatColor = heatColor
        needsDisplay = true
    }

    /// Selected rows (emphasized background style) draw no heat.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let heatIntensity, !isRowSelected else { return }
        let alpha = Self.heatAlpha(
            intensity: heatIntensity,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        guard alpha > 0 else { return }
        heatColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 4, yRadius: 4).fill()
    }

    private var isRowSelected: Bool {
        if backgroundStyle == .emphasized { return true }
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? NSTableRowView { return row.isSelected }
            ancestor = view.superview
        }
        return false
    }
}
