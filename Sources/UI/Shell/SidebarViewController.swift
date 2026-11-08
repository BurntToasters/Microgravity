import AppKit

/// Source-list navigation: Monitor and Inventory groups, Settings last, with a status footer.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((DashboardPage) -> Void)?

    private final class Node {
        let page: DashboardPage?
        let title: String
        let children: [Node]

        init(page: DashboardPage) {
            self.page = page
            title = page.title
            children = []
        }

        init(group title: String, pages: [DashboardPage]) {
            page = nil
            self.title = title
            children = pages.map { Node(page: $0) }
        }

        var isGroup: Bool { page == nil }
    }

    private static let roots: [Node] = [
        Node(group: String(localized: "Monitor"), pages: [.processes, .details, .performance, .history, .users]),
        Node(group: String(localized: "Inventory"), pages: [.startup, .services]),
        Node(page: .settings)
    ]

    static let supportURL = URL(string: "https://rosie.run/support")!

    private let monitoringStore: any MonitoringStore
    private let outlineView = NSOutlineView()
    private let footer: SidebarStatusFooter
    private let openURL: (URL) -> Void
    let supportButton = NSButton(title: String(localized: "Support Microgravity"), target: nil, action: nil)

    /// `openURL` opens a link in the user's default browser; tests replace it.
    init(monitoringStore: any MonitoringStore, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.monitoringStore = monitoringStore
        self.openURL = openURL
        footer = SidebarStatusFooter(monitoringStore: monitoringStore)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar.column"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.headerView = nil
        outlineView.floatsGroupRows = true
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("navigation.sidebar")
        outlineView.setAccessibilityLabel(String(localized: "Sections"))
        outlineView.reloadData()
        for root in Self.roots where root.isGroup {
            outlineView.expandItem(root)
        }

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        supportButton.target = self
        supportButton.action = #selector(openSupportPage)
        supportButton.bezelStyle = .push
        supportButton.controlSize = .small
        supportButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        supportButton.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        supportButton.imagePosition = .imageLeading
        supportButton.toolTip = String(localized: "Open \(Self.supportURL.absoluteString) in your browser")
        supportButton.setAccessibilityIdentifier("sidebar.support")
        supportButton.setAccessibilityLabel(String(localized: "Support Microgravity"))
        supportButton.setAccessibilityHelp(String(localized: "Opens the support page in your default browser."))
        supportButton.translatesAutoresizingMaskIntoConstraints = false

        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        view.addSubview(supportButton)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: supportButton.topAnchor, constant: -8),
            supportButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            supportButton.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor),
            supportButton.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    /// Highlights `page` without changing the displayed page; the caller shows it.
    func select(_ page: DashboardPage) {
        loadViewIfNeeded()
        guard let node = Self.allPageNodes.first(where: { $0.page == page }) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func refreshStatus(snapshot: MonitoringSnapshot? = nil) {
        footer.refresh(snapshot: snapshot)
    }

    /// Pauses the footer's 1 s timer while the window is hidden, minimized or fully covered.
    func setWindowVisible(_ visible: Bool) {
        footer.setWindowVisible(visible)
    }

    @objc func openSupportPage() {
        openURL(Self.supportURL)
    }

    private static let allPageNodes: [Node] = roots.flatMap { $0.isGroup ? $0.children : [$0] }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? Self.roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node)?.children ?? Self.roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isGroup
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.page != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let page = node.page {
            return makePageCell(for: page)
        }
        let text = NSTextField(labelWithString: node.title)
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.textColor = .secondaryLabelColor
        let cell = NSTableCellView()
        cell.textField = text
        cell.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? Node, let page = node.page else { return }
        onSelect?(page)
    }

    private func makePageCell(for page: DashboardPage) -> NSTableCellView {
        let identifier = "navigation.item.\(page.rawValue)"
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)
        cell.setAccessibilityIdentifier(identifier)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSTextField(labelWithString: page.title)
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        text.setAccessibilityIdentifier(identifier)

        cell.imageView = icon
        cell.textField = text
        cell.addSubview(icon)
        cell.addSubview(text)
        icon.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// Two-line sampling status pinned to the bottom of the sidebar.
@MainActor
final class SidebarStatusFooter: NSView {
    private let monitoringStore: any MonitoringStore
    private let samplingLine = NSTextField(labelWithString: "")
    private let freshnessLine = NSTextField(labelWithString: String(localized: "Waiting for the first sample"))
    private var refreshTimer: Timer?
    /// False while the window is hidden, minimized or fully covered. The timer does not run then.
    private var isWindowVisible = true

    init(monitoringStore: any MonitoringStore) {
        self.monitoringStore = monitoringStore
        super.init(frame: .zero)

        samplingLine.font = .systemFont(ofSize: 11, weight: .medium)
        samplingLine.textColor = .secondaryLabelColor
        samplingLine.setAccessibilityIdentifier("performance.sampling-state")
        freshnessLine.font = .systemFont(ofSize: 11)
        freshnessLine.textColor = .secondaryLabelColor
        freshnessLine.setAccessibilityIdentifier("process.freshness")
        for line in [samplingLine, freshnessLine] {
            line.lineBreakMode = .byTruncatingTail
            line.maximumNumberOfLines = 1
        }

        let stack = NSStackView(views: [samplingLine, freshnessLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(samplingStateChanged),
            name: .samplingStateDidChange, object: nil
        )
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    /// The 1 s timer runs only while the footer is in a window that is visible. Pause or interval changes made
    /// on other pages do not publish a snapshot, so the timer polls the store cheaply.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        updateTimer()
    }

    /// Starts the timer when the footer is shown and visible; invalidates it when the footer leaves its window.
    private func updateTimer() {
        guard window != nil, isWindowVisible else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        // Catch up on anything missed while the timer was paused.
        refresh()
    }

    func refresh(snapshot: MonitoringSnapshot? = nil) {
        let paused = monitoringStore.isPaused
        samplingLine.stringValue = paused
            ? String(localized: "Paused")
            : String(localized: "Sampling every \(SamplingControls.longTitle(monitoringStore.interval))")
        samplingLine.setAccessibilityLabel(samplingLine.stringValue)
        if let snapshot = snapshot ?? monitoringStore.latestSnapshot {
            let time = UIFormat.time(snapshot.timestamp)
            freshnessLine.stringValue = paused ? String(localized: "Last sample \(time)") : String(localized: "Updated \(time)")
        } else {
            freshnessLine.stringValue = String(localized: "Waiting for the first sample")
        }
        freshnessLine.setAccessibilityLabel(freshnessLine.stringValue)
    }

    @objc private func samplingStateChanged() {
        refresh()
    }

    @objc private func timerFired() {
        refresh()
    }
}
