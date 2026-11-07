import AppKit

/// One-line status bar (8 pt corners) for coverage, capability and failure messages.
///
/// Show it with `setMessage(_:style:)`; a nil or empty message hides it and removes it from layout.
/// Put a page's existing state identifier on the text via `setTextAccessibilityIdentifier(_:)`.
/// The full message is available as the tooltip when it truncates.
@MainActor
final class StatusBannerView: NSView {
    enum Style: Equatable {
        /// Neutral information: secondary text on a quaternary fill.
        case info
        /// Incomplete or degraded data: orange tint.
        case warning
        /// Failed or blocked: red tint.
        case error
    }

    private(set) var style: Style = .info
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var buttonAction: (() -> Void)?
    private let stack = NSStackView()

    init(style: Style = .info) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = #selector(buttonPressed)
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        apply(style: style)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// The text field, for layout or tests. Prefer `setMessage` to change its content.
    var textField: NSTextField { label }

    /// Shows `text` in `style`, or hides the banner when `text` is nil or empty.
    func setMessage(_ text: String?, style: Style = .info) {
        guard let text, !text.isEmpty else {
            label.stringValue = ""
            label.setAccessibilityLabel("")
            toolTip = nil
            isHidden = true
            return
        }
        self.style = style
        apply(style: style)
        label.stringValue = text
        label.setAccessibilityLabel(text)
        label.toolTip = text
        toolTip = text
        isHidden = false
    }

    /// Shows a trailing button with `title`; `action` runs on the main actor when it is pressed.
    func setButton(title: String, action: @escaping () -> Void) {
        button.title = title
        buttonAction = action
        button.isHidden = false
    }

    /// Removes the trailing button.
    func clearButton() {
        buttonAction = nil
        button.isHidden = true
    }

    /// Sets the accessibility identifier on the message text (for example `startup.discovery-state`).
    func setTextAccessibilityIdentifier(_ identifier: String) {
        label.setAccessibilityIdentifier(identifier)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor(for: style).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func apply(style: Style) {
        let symbol: String
        let tint: NSColor
        switch style {
        case .info:
            symbol = "info.circle"
            tint = .secondaryLabelColor
        case .warning:
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
        case .error:
            symbol = "xmark.octagon"
            tint = .systemRed
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        iconView.contentTintColor = tint
        label.textColor = style == .info ? .secondaryLabelColor : .labelColor
        needsDisplay = true
    }

    private func fillColor(for style: Style) -> NSColor {
        switch style {
        case .info: .quaternarySystemFill
        case .warning: NSColor.systemOrange.withAlphaComponent(0.14)
        case .error: NSColor.systemRed.withAlphaComponent(0.14)
        }
    }

    @objc private func buttonPressed() {
        buttonAction?()
    }
}
