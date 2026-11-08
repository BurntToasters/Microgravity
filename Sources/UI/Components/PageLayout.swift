import AppKit

/// Insets and spacing shared by every page: 20 pt horizontal, 12 pt below the toolbar.
@MainActor
enum PageLayout {
    static let horizontalInset: CGFloat = 20
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 20
    /// Gap between stacked page sections such as the header, a banner and a table.
    static let sectionSpacing: CGFloat = 12

    /// Constraints that pin `content` inside `page` using the shared insets.
    static func pin(_ content: NSView, in page: NSView) -> [NSLayoutConstraint] {
        [
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -horizontalInset),
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -bottomInset)
        ]
    }
}
