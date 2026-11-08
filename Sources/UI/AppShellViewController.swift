import AppKit

/// Declaration order is the sidebar's visual order (Monitor, Inventory, Settings), so View-menu ⌘1…⌘8 follow it.
enum DashboardPage: String, CaseIterable {
    case processes
    case details
    case performance
    case history
    case users
    case startup
    case services
    case settings

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .performance: return "Performance"
        case .history: return "App History"
        case .startup: return "Startup"
        case .users: return "Users"
        case .details: return "Details"
        case .services: return "Services"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .processes: return "list.bullet.rectangle"
        case .performance: return "chart.xyaxis.line"
        case .history: return "clock.arrow.circlepath"
        case .startup: return "power"
        case .users: return "person.2"
        case .details: return "list.bullet.rectangle.portrait"
        case .services: return "gearshape.2"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct PageDependencies {
    let monitoringStore: any MonitoringStore
    let processActions: any ProcessActioning
    let integrations: any SystemIntegrationAPI
    let fixtureMode: Bool
}

@MainActor
protocol SnapshotUpdating: AnyObject {
    func update(snapshot: MonitoringSnapshot)
}

@MainActor
final class RootViewController: NSViewController {
    private let dependencies: AppDependencies
    let sidebar: SidebarViewController
    private let pageHost: PageHostViewController
    private let splitController = NSSplitViewController()
    private var selectedPage: DashboardPage?

    /// Fires after the detail page changes. The window uses it to rebuild the page's toolbar items.
    var onPageChange: ((PageToolbarProviding?) -> Void)?

    var splitView: NSSplitView { splitController.splitView }
    var currentPageToolbarProvider: PageToolbarProviding? { pageHost.currentController as? PageToolbarProviding }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.sidebar = SidebarViewController(monitoringStore: dependencies.monitoringStore)
        self.pageHost = PageHostViewController(dependencies: dependencies)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        // Dynamic background: a CGColor snapshot here would not follow Light/Dark changes.
        view = DynamicWindowBackgroundView()
        view.translatesAutoresizingMaskIntoConstraints = false

        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: pageHost)
        contentItem.minimumThickness = 700
        contentItem.canCollapse = false
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        addChild(splitController)

        let splitView = splitController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onSelect = { [weak self] page in
            self?.showPage(page)
        }
        pageHost.onPageChange = { [weak self] controller in
            self?.onPageChange?(controller as? PageToolbarProviding)
        }
        dependencies.monitoringStore.onSnapshot = { [weak self] snapshot in
            self?.apply(snapshot: snapshot)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        select(.processes)
        if let snapshot = dependencies.monitoringStore.latestSnapshot {
            apply(snapshot: snapshot)
        }
    }

    func select(_ page: DashboardPage) {
        sidebar.select(page)
        showPage(page)
    }

    /// Opens Details and requests selection by complete process identity.
    func showProcessInDetails(_ identity: ProcessIdentity) {
        select(.details)
        (pageHost.currentController as? DetailsViewController)?.selectProcess(identity: identity)
    }

    /// Collapses or expands the sidebar; the split view controller owns the animation.
    @objc func toggleSidebar(_ sender: Any?) {
        splitController.toggleSidebar(sender)
    }

    private func apply(snapshot: MonitoringSnapshot) {
        pageHost.update(snapshot: snapshot)
        sidebar.refreshStatus(snapshot: snapshot)
    }

    /// Minimized, hidden or fully covered windows skip page updates and pause the sidebar timer.
    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === view.window else { return }
        let visible = window.occlusionState.contains(.visible)
        pageHost.setWindowVisible(visible)
        sidebar.setWindowVisible(visible)
    }

    private func showPage(_ page: DashboardPage) {
        guard selectedPage != page else { return }
        selectedPage = page
        pageHost.show(page: page)
    }
}

@MainActor
private final class PageHostViewController: NSViewController {
    private let dependencies: AppDependencies
    private var currentPage: DashboardPage?
    private var cachedControllers: [DashboardPage: NSViewController] = [:]
    private var currentConstraints: [NSLayoutConstraint] = []
    private var latestSnapshot: MonitoringSnapshot?
    private(set) var currentController: NSViewController?
    var onPageChange: ((NSViewController?) -> Void)?
    /// False while the window is minimized, hidden or fully covered. Sampling continues; page work does not.
    private var isWindowVisible = true
    /// True when the latest snapshot has not yet been pushed to the current page.
    private var pageNeedsSnapshot = false

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let page = DynamicWindowBackgroundView()
        view = page
    }

    func update(snapshot: MonitoringSnapshot) {
        latestSnapshot = snapshot
        pageNeedsSnapshot = true
        pushLatestSnapshotIfVisible()
    }

    /// Pushes the latest snapshot as soon as a hidden window becomes visible again.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        pushLatestSnapshotIfVisible()
    }

    private func pushLatestSnapshotIfVisible() {
        guard isWindowVisible, pageNeedsSnapshot, let latestSnapshot else { return }
        pageNeedsSnapshot = false
        (currentController as? SnapshotUpdating)?.update(snapshot: latestSnapshot)
    }

    func show(page: DashboardPage) {
        guard currentPage != page else { return }
        currentPage = page
        detachCurrentController()
        let controller = cachedControllers[page] ?? makeController(for: page)
        cachedControllers[page] = controller
        attach(controller)
        currentController = controller
        pageNeedsSnapshot = latestSnapshot != nil
        pushLatestSnapshotIfVisible()
        onPageChange?(controller)
    }

    private func makeController(for page: DashboardPage) -> NSViewController {
        let context = PageDependencies(
            monitoringStore: dependencies.monitoringStore,
            processActions: dependencies.processActions,
            integrations: dependencies.integrations,
            fixtureMode: dependencies.fixtureMode
        )
        switch page {
        case .processes: return ProcessesViewController(dependencies: context)
        case .performance: return PerformanceViewController(dependencies: context)
        case .history: return HistoryViewController(dependencies: context)
        case .startup: return InventoryViewController(kind: .startup, dependencies: context)
        case .users: return UsersViewController()
        case .details:
            // Fixture launches keep column layout out of the app's real defaults domain.
            return context.fixtureMode ? DetailsViewController(autosaveName: nil) : DetailsViewController()
        case .services: return InventoryViewController(kind: .services, dependencies: context)
        case .settings: return SettingsViewController(dependencies: context)
        }
    }

    private func attach(_ controller: NSViewController) {
        addChild(controller)
        let pageView = controller.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        // Start below the unified toolbar: the window uses full-size content.
        currentConstraints = [
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ]
        NSLayoutConstraint.activate(currentConstraints)
    }

    private func detachCurrentController() {
        guard let controller = currentController else { return }
        NSLayoutConstraint.deactivate(currentConstraints)
        currentConstraints = []
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        currentController = nil
    }
}

@MainActor
enum UIComponents {
    static func header(title: String, subtitle: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        heading.textColor = .labelColor
        heading.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [heading]
        if !subtitle.isEmpty {
            // One line only; the full explanation lives in the tooltip.
            let caption = NSTextField(labelWithString: subtitle)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.maximumNumberOfLines = 1
            caption.lineBreakMode = .byTruncatingTail
            caption.toolTip = subtitle
            views.append(caption)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.toolTip = subtitle.isEmpty ? nil : subtitle
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func label(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        return field
    }

    static func scrollView(document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = document
        return scroll
    }

    static func card(title: String, subtitle: String? = nil, identifier: String? = nil,
                     titleLabel: NSTextField? = nil, content: NSView) -> NSView {
        let card = CardContainerView()
        if let identifier { card.setAccessibilityIdentifier(identifier) }

        let titleField = titleLabel ?? label(title, size: 13, weight: .semibold)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        rows.addArrangedSubview(titleField)
        if let subtitle { rows.addArrangedSubview(label(subtitle, size: 11, color: .secondaryLabelColor)) }
        content.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(content)
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        return card
    }
}

@MainActor
private final class CardContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
final class DynamicWindowBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
