import AppKit
import ServiceManagement

enum InventoryKind {
    case startup
    case services

    var title: String {
        switch self {
        case .startup: return "Startup"
        case .services: return "Services"
        }
    }

    var coverageKey: String {
        switch self {
        case .startup: return "startupItems"
        case .services: return "services"
        }
    }

    var pageIdentifier: String {
        switch self {
        case .startup: return "startup"
        case .services: return "services"
        }
    }
}

/// Read-only Startup and Services page. Coverage is a banner; the selected item's path sits in a bottom bar.
@MainActor
final class InventoryViewController: NSViewController, SnapshotUpdating, PageToolbarProviding {
    private let kind: InventoryKind
    private let dependencies: PageDependencies
    private let table: InventoryTableController
    private let banner = StatusBannerView(style: .info)
    private let pathLabel = NSTextField(labelWithString: "Select an item to inspect its path.")
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let toolbarRevealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let toolbarSettingsButton = NSButton(title: "Open Login Items Settings", target: nil, action: nil)
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var rowsByID: [String: InventoryRow] = [:]
    private var selectedEntry: DiscoveredEntrySnapshot?
    private var coverageReasons: [String] = []
    private var coverageDetailsPopover: NSPopover?

    private var revealIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("\(kind.pageIdentifier).toolbar.reveal")
    }

    private var loginItemsIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("\(kind.pageIdentifier).toolbar.login-items")
    }

    /// Fixture launches get no autosave name so UI tests never read or write the app's real column state.
    static func tableAutosaveName(for kind: InventoryKind, fixtureMode: Bool) -> String? {
        fixtureMode ? nil : "\(kind.pageIdentifier).table"
    }

    init(kind: InventoryKind, dependencies: PageDependencies) {
        self.kind = kind
        self.dependencies = dependencies
        table = InventoryTableController(identifier: "\(kind.pageIdentifier).table",
                                         autosaveName: Self.tableAutosaveName(for: kind, fixtureMode: dependencies.fixtureMode),
                                         accessibilityLabel: kind.title)
        super.init(nibName: nil, bundle: nil)
        table.onSelectionChanged = { [weak self] rowID in
            guard let self else { return }
            selectedEntry = rowID.flatMap { self.rowsByID[$0]?.entry }
            updateSelectedItem()
        }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: PageToolbarProviding

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] { [revealIdentifier, loginItemsIdentifier] }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if let item = toolbarItems[identifier] { return item }
        let item: NSToolbarItem
        if identifier == revealIdentifier {
            configureToolbarButton(toolbarRevealButton, title: "Reveal in Finder", symbol: "folder",
                                   identifier: "\(kind.pageIdentifier).toolbar.reveal",
                                   action: #selector(revealSelectedPath))
            toolbarRevealButton.isEnabled = false
            item = makeToolbarItem(identifier, label: "Reveal in Finder", button: toolbarRevealButton,
                                   menuTitle: "Reveal in Finder", action: #selector(revealSelectedPath))
        } else if identifier == loginItemsIdentifier {
            configureToolbarButton(toolbarSettingsButton, title: "Open Login Items Settings", symbol: "gearshape",
                                   identifier: "\(kind.pageIdentifier).action.open-settings",
                                   action: #selector(openLoginItemsSettings))
            item = makeToolbarItem(identifier, label: "Open Login Items Settings", button: toolbarSettingsButton,
                                   menuTitle: "Open Login Items Settings", action: #selector(openLoginItemsSettings))
        } else {
            return nil
        }
        toolbarItems[identifier] = item
        return item
    }

    // MARK: View

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: kind.title,
            subtitle: "Read-only. Discovery may be incomplete when locations are protected."
        )
        banner.setTextAccessibilityIdentifier("\(kind.pageIdentifier).discovery-state")

        revealButton.target = self
        revealButton.action = #selector(revealSelectedPath)
        revealButton.controlSize = .small
        revealButton.font = .systemFont(ofSize: 11)
        revealButton.isEnabled = false
        revealButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.reveal-path")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setAccessibilityIdentifier("\(kind.pageIdentifier).selection.path")

        let separator = NSBox()
        separator.boxType = .separator
        let bar = NSStackView(views: [pathLabel, NSView(), revealButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        let footer = NSStackView(views: [separator, bar])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8

        let scroll = table.scrollView
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSStackView(views: [header, banner, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate(PageLayout.pin(content, in: view) + [
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            banner.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.widthAnchor.constraint(equalTo: footer.widthAnchor),
            bar.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let entries = kind == .startup ? snapshot.startupItems : snapshot.services
        let rows = InventoryRows.rows(for: entries, pageIdentifier: kind.pageIdentifier)
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let coverage = coverage(snapshot)

        table.update(rows: rows)
        updateBanner(coverage: coverage, count: entries.count)
        let empty = emptyStateText(coverage: coverage)
        table.setEmptyState(title: empty.title, caption: empty.caption)
        selectedEntry = table.selectedRowID.flatMap { rowsByID[$0]?.entry }
        updateSelectedItem()
    }

    private func updateBanner(coverage: DiscoveryCoverage?, count: Int) {
        coverageReasons = coverage?.reasons ?? []
        guard let coverage else {
            banner.setMessage("Discovery status unavailable · completeness is unknown.", style: .warning)
            banner.clearButton()
            return
        }
        if coverage.complete {
            banner.setMessage("Discovery complete · \(count == 1 ? "1 entry" : "\(count) entries") found", style: .info)
            banner.clearButton()
            return
        }
        banner.setMessage("Discovery incomplete · " + (coverage.reasons.first ?? "Some locations could not be inspected."),
                          style: .warning)
        if coverage.reasons.isEmpty {
            banner.clearButton()
        } else {
            banner.setButton(title: "Details…") { [weak self] in self?.showCoverageDetails() }
        }
    }

    private func emptyStateText(coverage: DiscoveryCoverage?) -> (title: String, caption: String) {
        let title = kind == .startup ? "No startup items found" : "No services found"
        guard let coverage else { return (title, "Discovery status is unknown.") }
        if !coverage.complete {
            return (title, "Discovery is incomplete, so entries may be missing.")
        }
        return (title, kind == .startup
            ? "Login items and launch agents appear here when they are registered."
            : "Discovered system services appear here.")
    }

    private func updateSelectedItem() {
        guard let selectedEntry else {
            revealButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.reveal-path")
            revealButton.isEnabled = false
            toolbarRevealButton.isEnabled = false
            pathLabel.stringValue = rowsByID.isEmpty ? "No entries to inspect." : "Select an item to inspect its path."
            pathLabel.toolTip = nil
            return
        }
        revealButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.reveal-path.\(slug(selectedEntry.id))")
        let hasPath = selectedEntry.path != nil
        revealButton.isEnabled = hasPath
        toolbarRevealButton.isEnabled = hasPath
        pathLabel.stringValue = selectedEntry.path ?? "No executable path was reported for this item."
        pathLabel.toolTip = selectedEntry.path
    }

    private func coverage(_ snapshot: MonitoringSnapshot) -> DiscoveryCoverage? {
        if let exact = snapshot.discoveryCoverage[kind.coverageKey] { return exact }
        let token = kind == .startup ? "startup" : "service"
        return snapshot.discoveryCoverage.first(where: { $0.key.lowercased().contains(token) })?.value
    }

    // MARK: Actions

    @objc private func revealSelectedPath() {
        guard let path = selectedEntry?.path else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func showCoverageDetails() {
        let popover = NSPopover()
        popover.behavior = .transient
        let content = makeCoverageDetailsView(coverageReasons)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.show(relativeTo: banner.bounds, of: banner, preferredEdge: .minY)
        coverageDetailsPopover = popover
    }

    private func makeCoverageDetailsView(_ reasons: [String]) -> NSView {
        let title = UIComponents.label("Discovery details", size: 13, weight: .semibold)
        let reasonLabels = reasons.map { reason -> NSTextField in
            let field = NSTextField(wrappingLabelWithString: reason)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.preferredMaxLayoutWidth = 300
            return field
        }
        let stack = NSStackView(views: [title] + reasonLabels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 324, height: 80))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        container.frame.size.height = stack.fittingSize.height + 24
        return container
    }

    private func configureToolbarButton(_ button: NSButton, title: String, symbol: String,
                                        identifier: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .toolbar
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    private func makeToolbarItem(_ identifier: NSToolbarItem.Identifier, label: String, button: NSButton,
                                 menuTitle: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.view = button
        let menuItem = NSMenuItem(title: menuTitle, action: action, keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        return item
    }

    private func slug(_ value: String) -> String {
        UIText.slug(value)
    }
}
