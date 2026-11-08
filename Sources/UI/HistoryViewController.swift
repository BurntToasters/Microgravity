import AppKit

@MainActor
final class HistoryViewController: NSViewController, SnapshotUpdating, PageToolbarProviding {
    private static let resetItemIdentifier = NSToolbarItem.Identifier("history.toolbar.reset")

    private let dependencies: PageDependencies
    private let outlineController: AppHistoryOutlineController
    private let banner = StatusBannerView(style: .info)
    private var resetItem: NSToolbarItem?

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        if dependencies.fixtureMode,
           let fixtureSuite = ProcessInfo.processInfo.environment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"] {
            clearFixtureTableAutosave(named: "history.outline.\(fixtureSuite)")
        }
        outlineController = AppHistoryOutlineController(autosaveName: dependencies.fixtureMode ? nil : "history.outline")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: PageToolbarProviding

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] { [Self.resetItemIdentifier] }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard identifier == Self.resetItemIdentifier else { return nil }
        if let resetItem { return resetItem }
        let button = NSButton(title: "Reset History…", target: self, action: #selector(confirmReset))
        button.bezelStyle = .texturedRounded
        button.setAccessibilityIdentifier("history.action.reset")
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Reset History"
        item.paletteLabel = "Reset History"
        item.toolTip = "Clear the stored 30-day app history. Process and system state are not changed."
        item.view = button
        let menuItem = NSMenuItem(title: "Reset History…", action: #selector(confirmReset), keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        resetItem = item
        return item
    }

    // MARK: View

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "App History",
            subtitle: "Per-app CPU, disk, and network totals. Gaps and counter resets stay visible."
        )
        let range = UIComponents.label("Last 30 days", size: 12, weight: .semibold, color: .secondaryLabelColor)
        range.setAccessibilityIdentifier("history.range.30-days")
        let headerRow = NSStackView(views: [header, NSView(), range])
        headerRow.orientation = .horizontal
        headerRow.alignment = .top

        banner.setTextAccessibilityIdentifier("history.capability-state")
        let scroll = outlineController.scrollView
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let content = NSStackView(views: [headerRow, banner, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate(PageLayout.pin(content, in: view) + [
            headerRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            banner.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let summary = AppHistoryBuilder.summarize(snapshot.applicationHistory, through: snapshot.timestamp)
        let availability = snapshot.capabilities[.history]
        outlineController.update(groups: summary.groups)

        let status = AppHistoryStatus.banner(
            availability: availability,
            applicationCount: summary.groups.count,
            gaps: summary.gaps,
            counterResets: summary.counterResets,
            timestamp: snapshot.timestamp
        )
        banner.setMessage(status.text, style: status.style)

        let empty = AppHistoryStatus.emptyState(availability: availability)
        outlineController.setEmptyState(title: empty.title, caption: empty.caption)
    }

    // MARK: Reset

    @objc private func confirmReset() {
        Task { @MainActor [weak self] in
            guard let self, let window = view.window else { return }
            let response = await SheetAlert.present(
                on: window,
                style: .warning,
                messageText: "Reset App History",
                informativeText: "This clears Microgravity’s stored 30-day aggregate history. It does not change process or operating-system state.",
                buttons: ["Reset History", "Cancel"],
                defaultButtonIdentifier: "history.reset.confirm"
            )
            guard response == .alertFirstButtonReturn else { return }
            do {
                try await dependencies.monitoringStore.resetHistory()
            } catch {
                await showResetError(error.localizedDescription, on: window)
            }
        }
    }

    private func showResetError(_ message: String, on window: NSWindow) async {
        await SheetAlert.present(
            on: window,
            style: .warning,
            messageText: "History could not be reset",
            informativeText: message,
            buttons: ["OK"]
        )
    }
}
