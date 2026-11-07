import AppKit

/// Color of a leading status dot. Shared by the Settings integration rows and the Inventory status column.
enum StatusTone: Equatable {
    /// Available, enabled, running, loaded, or up to date.
    case positive
    /// Not configured, disabled, not checked, not reported, or unavailable on this system.
    case neutral
    /// Needs the user (requires approval, an update is ready) or is stopped.
    case attention
    /// Failed.
    case failure

    var color: NSColor {
        switch self {
        case .positive: .systemGreen
        case .neutral: .systemGray
        case .attention: .systemOrange
        case .failure: .systemRed
        }
    }
}

/// An 8 pt filled circle that sits before a status label. Decorative: the adjacent text carries the meaning.
@MainActor
final class StatusDotView: NSView {
    var tone: StatusTone {
        didSet { if tone != oldValue { needsDisplay = true } }
    }

    init(tone: StatusTone = .neutral) {
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        tone.color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
