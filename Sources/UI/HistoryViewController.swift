import AppKit

@MainActor
final class HistoryViewController: NSViewController, SnapshotUpdating, PageToolbarProviding {
    /// UserDefaults key for the "Show Background Processes" choice.
    static let showsBackgroundProcessesDefaultsKey = "history.showBackgroundProcesses"
    private static let resetItemIdentifier = NSToolbarItem.Identifier("history.toolbar.reset")
    private static let backgroundItemIdentifier = NSToolbarItem.Identifier("history.toolbar.background")

    private let dependencies: PageDependencies
    private let defaults: UserDefaults
    private let outlineController: AppHistoryOutlineController
    private let banner = StatusBannerView(style: .info)
    private let backgroundButton = NSButton(checkboxWithTitle: "Show Background Processes", target: nil, action: nil)
    private var resetItem: NSToolbarItem?
    private var backgroundItem: NSToolbarItem?
    private var lastSnapshot: MonitoringSnapshot?
    private(set) var showsBackgroundProcesses: Bool

    /// Fixture runs read and write their own defaults suite, never the app's real domain.
    /// - Parameter defaults: Overrides the store. Tests pass an isolated suite.
    init(dependencies: PageDependencies, defaults: UserDefaults? = nil) {
        self.dependencies = dependencies
        self.defaults = defaults ?? Self.defaultsStore(fixtureMode: dependencies.fixtureMode)
        if dependencies.fixtureMode,
           let fixtureSuite = ProcessInfo.processInfo.environment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"] {
            clearFixtureTableAutosave(named: "history.outline.\(fixtureSuite)")
        }
        outlineController = AppHistoryOutlineController(autosaveName: dependencies.fixtureMode ? nil : "history.outline")
        showsBackgroundProcesses = self.defaults.bool(forKey: Self.showsBackgroundProcessesDefaultsKey)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func defaultsStore(fixtureMode: Bool) -> UserDefaults {
        guard fixtureMode else { return .standard }
        let suite = ProcessInfo.processInfo.environment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"] ?? "Microgravity.fixtures"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    // MARK: PageToolbarProviding

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] { [Self.backgroundItemIdentifier, Self.resetItemIdentifier] }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if identifier == Self.backgroundItemIdentifier { return backgroundToolbarItem(identifier) }
        guard identifier == Self.resetItemIdentifier else { return nil }
        if let resetItem { return resetItem }
        let button = NSButton(title: "Reset History…", target: self, action: #selector(confirmReset))
        button.bezelStyle = .toolbar
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

    private func backgroundToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        if let backgroundItem { return backgroundItem }
        backgroundButton.target = self
        backgroundButton.action = #selector(toggleBackgroundProcesses(_:))
        backgroundButton.state = showsBackgroundProcesses ? .on : .off
        backgroundButton.setAccessibilityIdentifier("history.action.show-background")
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Show Background Processes"
        item.paletteLabel = "Show Background Processes"
        item.toolTip = "Include background daemons and services, not only applications you open."
        item.view = backgroundButton
        let menuItem = NSMenuItem(title: "Show Background Processes", action: #selector(toggleBackgroundProcesses(_:)),
                                  keyEquivalent: "")
        menuItem.target = self
        menuItem.state = backgroundButton.state
        item.menuFormRepresentation = menuItem
        backgroundItem = item
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
        lastSnapshot = snapshot
        render(snapshot)
    }

    private func render(_ snapshot: MonitoringSnapshot) {
        let summary = AppHistoryBuilder.summarize(snapshot.applicationHistory, through: snapshot.timestamp,
                                                  showsBackgroundProcesses: showsBackgroundProcesses)
        let availability = snapshot.capabilities[.history]
        outlineController.update(groups: summary.groups)

        let status = AppHistoryStatus.banner(
            availability: availability,
            applicationCount: summary.groups.count,
            hiddenBackgroundCount: summary.hiddenBackgroundCount,
            gaps: summary.gaps,
            counterResets: summary.counterResets,
            timestamp: snapshot.timestamp
        )
        banner.setMessage(status.text, style: status.style)

        let empty = AppHistoryStatus.emptyState(
            availability: availability,
            hiddenBackgroundCount: summary.groups.isEmpty ? summary.hiddenBackgroundCount : 0
        )
        outlineController.setEmptyState(title: empty.title, caption: empty.caption)
    }

    // MARK: Actions

    @objc private func toggleBackgroundProcesses(_ sender: Any?) {
        // The checkbox sets its own state; the menu item just flips the choice.
        let next = (sender as? NSButton).map { $0.state == .on } ?? !showsBackgroundProcesses
        showsBackgroundProcesses = next
        defaults.set(next, forKey: Self.showsBackgroundProcessesDefaultsKey)
        backgroundButton.state = next ? .on : .off
        backgroundItem?.menuFormRepresentation?.state = next ? .on : .off
        if let lastSnapshot { render(lastSnapshot) }
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
                defaultButtonIdentifier: "history.reset.confirm",
                destructiveButtonIndex: 0
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
