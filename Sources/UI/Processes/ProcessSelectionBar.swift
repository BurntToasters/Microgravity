import AppKit

/// Slim strip under the process table: icon, name, "PID · user · path", and the identity on the trailing edge.
///
/// The trailing label keeps the `process.selection.identity` identifier. It shows the start time; the PID is
/// already in the summary, and the label's accessibility text names both. An Inspect button sits after it
/// while a process is selected and calls `onInspect`.
@MainActor
final class ProcessSelectionBar: NSView {
    static let height: CGFloat = 36

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let summaryField = NSTextField(labelWithString: "")
    private let identityField = NSTextField(labelWithString: "")
    private let inspectButton = NSButton(title: String(localized: "Inspect"), target: nil, action: nil)

    /// Called when the user presses Inspect.
    var onInspect: (() -> Void)?

    /// Shown before the first snapshot, and with no selection when the page has no summary to show.
    static let emptyMessage = String(localized: "Select a process to inspect its identity.")

    init() {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: AppIconProvider.pointSize).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: AppIconProvider.pointSize).isActive = true

        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityIdentifier("process.selection.name")
        titleField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        summaryField.font = .systemFont(ofSize: 11)
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingMiddle
        summaryField.maximumNumberOfLines = 1
        summaryField.setAccessibilityIdentifier("process.selection.summary")
        summaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        identityField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        identityField.textColor = .secondaryLabelColor
        identityField.lineBreakMode = .byTruncatingTail
        identityField.maximumNumberOfLines = 1
        identityField.alignment = .right
        identityField.setAccessibilityIdentifier("process.selection.identity")
        identityField.setContentCompressionResistancePriority(.required, for: .horizontal)
        identityField.setContentHuggingPriority(.required, for: .horizontal)

        inspectButton.bezelStyle = .rounded
        inspectButton.controlSize = .small
        inspectButton.target = self
        inspectButton.action = #selector(inspectPressed(_:))
        inspectButton.setAccessibilityIdentifier("process.selection.inspect")
        inspectButton.setAccessibilityLabel(String(localized: "Inspect process"))
        inspectButton.toolTip = String(localized: "Show details for the selected process")
        inspectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        inspectButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, titleField, summaryField, identityField, inspectButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height)
        ])
        showEmpty()
    }

    required init?(coder: NSCoder) { nil }

    /// Clears the bar. `summary` replaces the empty-state message, for example "3 processes · 2 apps".
    func showEmpty(summary: String? = nil) {
        let text = summary ?? Self.emptyMessage
        iconView.image = nil
        iconView.isHidden = true
        titleField.stringValue = ""
        summaryField.stringValue = text
        summaryField.setAccessibilityLabel(text)
        identityField.stringValue = ""
        identityField.setAccessibilityLabel("")
        inspectButton.isHidden = true
    }

    func show(title: String, summary: String, identity: String, identityAccessibilityLabel: String? = nil, icon: NSImage) {
        iconView.isHidden = false
        iconView.image = icon
        titleField.stringValue = title
        summaryField.stringValue = summary
        summaryField.setAccessibilityLabel(summary)
        identityField.stringValue = identity
        identityField.setAccessibilityLabel(identityAccessibilityLabel ?? identity)
        inspectButton.isHidden = false
    }

    @objc private func inspectPressed(_ sender: Any?) {
        onInspect?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
