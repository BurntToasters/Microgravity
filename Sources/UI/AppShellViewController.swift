import AppKit

enum DashboardPage: String, CaseIterable {
    case processes
    case performance
    case history
    case startup
    case users
    case details
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
    private let sidebar = SidebarViewController()
    private let pageHost: PageHostViewController
    private let splitController = NSSplitViewController()

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.pageHost = PageHostViewController(dependencies: dependencies)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 205
        sidebarItem.maximumThickness = 265
        sidebarItem.canCollapse = false
        let contentItem = NSSplitViewItem(viewController: pageHost)
        contentItem.minimumThickness = 650
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
            self?.pageHost.show(page: page)
        }
        sidebar.select(.processes)
        dependencies.monitoringStore.onSnapshot = { [weak pageHost] snapshot in
            pageHost?.update(snapshot: snapshot)
        }
        if let snapshot = dependencies.monitoringStore.latestSnapshot {
            pageHost.update(snapshot: snapshot)
        }
    }
}

@MainActor
private final class SidebarViewController: NSViewController {
    var onSelect: ((DashboardPage) -> Void)?
    private var buttons: [DashboardPage: NSButton] = [:]

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect

        let brand = NSStackView()
        brand.orientation = .vertical
        brand.alignment = .leading
        brand.spacing = 3
        brand.translatesAutoresizingMaskIntoConstraints = false
        let appName = NSTextField(labelWithString: "MICROGRAVITY")
        appName.font = .systemFont(ofSize: 12, weight: .bold)
        appName.textColor = .secondaryLabelColor
        let appSubtitle = NSTextField(labelWithString: "SYSTEM MONITOR")
        appSubtitle.font = .systemFont(ofSize: 10, weight: .medium)
        appSubtitle.textColor = .tertiaryLabelColor
        brand.addArrangedSubview(appName)
        brand.addArrangedSubview(appSubtitle)

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.distribution = .fill
        navigation.spacing = 4
        navigation.translatesAutoresizingMaskIntoConstraints = false
        for page in DashboardPage.allCases {
            let button = makeButton(page)
            buttons[page] = button
            navigation.addArrangedSubview(button)
        }

        let footer = NSTextField(labelWithString: "Local system data")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [brand, navigation, NSView(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            navigation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        stack.setCustomSpacing(26, after: brand)
        stack.setCustomSpacing(14, after: navigation)
    }

    func select(_ page: DashboardPage) {
        for (candidate, button) in buttons {
            button.state = candidate == page ? .on : .off
        }
        onSelect?(page)
    }

    private func makeButton(_ page: DashboardPage) -> NSButton {
        let button = NSButton(title: page.title, target: self, action: #selector(didSelectPage(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("navigation.item.\(page.rawValue)")
        button.setAccessibilityIdentifier("navigation.item.\(page.rawValue)")
        button.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = .secondaryLabelColor
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.alignment = .left
        button.isBordered = false
        button.bezelStyle = .rounded
        button.setButtonType(.toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 34),
            button.widthAnchor.constraint(equalToConstant: 224)
        ])
        button.tag = DashboardPage.allCases.firstIndex(of: page) ?? 0
        return button
    }

    @objc private func didSelectPage(_ sender: NSButton) {
        let pages = DashboardPage.allCases
        guard pages.indices.contains(sender.tag) else { return }
        select(pages[sender.tag])
    }
}

@MainActor
private final class PageHostViewController: NSViewController {
    private let dependencies: AppDependencies
    private var currentPage: DashboardPage?
    private var currentController: NSViewController?
    private var latestSnapshot: MonitoringSnapshot?

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
        (currentController as? SnapshotUpdating)?.update(snapshot: snapshot)
    }

    func show(page: DashboardPage) {
        guard currentPage != page else { return }
        currentPage = page
        currentController?.view.removeFromSuperview()
        currentController?.removeFromParent()
        let context = PageDependencies(
            monitoringStore: dependencies.monitoringStore,
            processActions: dependencies.processActions,
            integrations: dependencies.integrations,
            fixtureMode: dependencies.fixtureMode
        )
        let controller: NSViewController
        switch page {
        case .processes: controller = ProcessesViewController(dependencies: context)
        case .performance: controller = PerformanceViewController(dependencies: context)
        case .history: controller = HistoryViewController(dependencies: context)
        case .startup: controller = InventoryViewController(kind: .startup, dependencies: context)
        case .users: controller = UsersViewController()
        case .details: controller = DetailsViewController()
        case .services: controller = InventoryViewController(kind: .services, dependencies: context)
        case .settings: controller = SettingsViewController(dependencies: context)
        }
        addChild(controller)
        let pageView = controller.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        currentController = controller
        if let latestSnapshot {
            (controller as? SnapshotUpdating)?.update(snapshot: latestSnapshot)
        }
    }
}

@MainActor
enum UIComponents {
    static func header(title: String, subtitle: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        heading.textColor = .labelColor
        let caption = NSTextField(labelWithString: subtitle)
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2
        let stack = NSStackView(views: [heading, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
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
