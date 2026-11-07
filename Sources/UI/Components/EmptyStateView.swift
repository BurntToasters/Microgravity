import AppKit

/// Centered placeholder (symbol, title, optional caption) shown over a table when it has no rows.
///
/// Install it over a scroll view with `install(in:)`, then toggle `isHidden` as rows come and go.
/// The view is click-through, so it never blocks the table underneath.
@MainActor
final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    /// - Parameters:
    ///   - symbolName: SF Symbol shown above the title.
    ///   - title: One short line, for example "No processes match".
    ///   - caption: Optional supporting sentence.
    init(symbolName: String = "tray", title: String, caption: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.alignment = .center
        captionLabel.maximumNumberOfLines = 0
        captionLabel.preferredMaxLayoutWidth = 300

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(captionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
        update(symbolName: symbolName, title: title, caption: caption)
    }

    required init?(coder: NSCoder) { nil }

    /// Changes the text and symbol, for example when a search filter changes the reason rows are empty.
    func update(symbolName: String, title: String, caption: String?) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        titleLabel.stringValue = title
        captionLabel.stringValue = caption ?? ""
        captionLabel.isHidden = (caption ?? "").isEmpty
    }

    /// Click-through: hit tests fall through to the table underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Adds a centered empty state over `scrollView` and returns it. It starts hidden; the caller shows it when rows are empty.
    @discardableResult
    static func install(in scrollView: NSScrollView, symbolName: String = "tray",
                        title: String, caption: String? = nil) -> EmptyStateView {
        let view = EmptyStateView(symbolName: symbolName, title: title, caption: caption)
        view.isHidden = true
        scrollView.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16)
        ])
        return view
    }
}
