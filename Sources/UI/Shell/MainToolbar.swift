import AppKit

/// Adopted by page view controllers that contribute trailing items to the unified toolbar.
///
/// The shell rebuilds the trailing items whenever the page changes: it removes the previous page's
/// items, inserts `toolbarItemIdentifiers`, and asks `toolbarItem(for:)` to build each one. Return
/// `nil` for identifiers you do not own.
@MainActor
protocol PageToolbarProviding: AnyObject {
    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] { get }
    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem?
}

/// Owns the window's single `NSToolbar`: sidebar toggle, sidebar tracking separator, flexible space,
/// then the current page's trailing items.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    static let sidebarSeparatorIdentifier = NSToolbarItem.Identifier("Microgravity.sidebarSeparator")
    private static let leadingIdentifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar,
        sidebarSeparatorIdentifier,
        .flexibleSpace
    ]

    let toolbar: NSToolbar
    private weak var splitView: NSSplitView?
    private var pageProvider: PageToolbarProviding?

    init(splitView: NSSplitView) {
        self.splitView = splitView
        // AppKit shares inserted-item state by toolbar identifier across live toolbars. A second live window
        // (the test host already has one) with the same identifier rejects page items as duplicates.
        // Autosave is off, so a per-instance identifier costs nothing.
        toolbar = NSToolbar(identifier: "Microgravity.MainToolbar.\(UUID().uuidString)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    /// Replaces the trailing page items. Call after the toolbar is attached to a window.
    func setPage(_ provider: PageToolbarProviding?) {
        pageProvider = provider
        let leadingCount = Self.leadingIdentifiers.count
        while toolbar.items.count > leadingCount {
            toolbar.removeItem(at: leadingCount)
        }
        for identifier in provider?.toolbarItemIdentifiers ?? [] {
            toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.leadingIdentifiers + (pageProvider?.toolbarItemIdentifiers ?? [])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.leadingIdentifiers + (pageProvider?.toolbarItemIdentifiers ?? [])
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.sidebarSeparatorIdentifier, let splitView {
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        }
        return pageProvider?.toolbarItem(for: itemIdentifier)
    }
}
