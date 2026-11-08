import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 1280, height: 820)
    static let minimumContentSize = NSSize(width: 960, height: 600)
    static let helpURL = URL(string: "https://github.com/BurntToasters/Microgravity")!
    static let issuesURL = URL(string: "https://github.com/BurntToasters/Microgravity/issues")!
    nonisolated static let frameAutosaveName = "Main"
    private static let fixtureVisualWindowIdentifier = NSUserInterfaceItemIdentifier("ui-test.visual-window")
    private static let fixtureContentSizeArgumentPrefix = "--ui-test-window-content-size="

    private let dependencies: AppDependencies
    let root: RootViewController
    private let mainToolbar: MainToolbar

    /// `initialContentSize` is only supplied by DEBUG fixture launches; nil opens at `defaultContentSize`.
    init(dependencies: AppDependencies, frameAutosaveName: String? = MainWindowController.frameAutosaveName,
         identifiesFixtureVisualWindow: Bool = false, initialContentSize: NSSize? = nil) {
        self.dependencies = dependencies
        let root = RootViewController(dependencies: dependencies)
        let window = Self.makeWindow(root: root, frameAutosaveName: frameAutosaveName,
                                     initialContentSize: initialContentSize ?? Self.defaultContentSize)
        if identifiesFixtureVisualWindow {
            window.identifier = Self.fixtureVisualWindowIdentifier
        }
        let mainToolbar = MainToolbar(splitView: root.splitView)
        window.toolbar = mainToolbar.toolbar
        self.root = root
        self.mainToolbar = mainToolbar
        super.init(window: window)

        // The first page was chosen while the root loaded, before this callback existed.
        mainToolbar.setPage(root.currentPageToolbarProvider)
        root.onPageChange = { [weak self] provider in
            self?.mainToolbar.setPage(provider)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Sets the content controller first so the window is sized from the real content, then
    /// applies the intended size. Autosave comes last so a saved frame from a previous launch wins.
    private static func makeWindow(root: RootViewController, frameAutosaveName: String?,
                                   initialContentSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Microgravity"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentViewController = root
        // Content minimum only: NSWindow derives the frame minimum from it, including the title bar.
        window.contentMinSize = minimumContentSize
        window.setContentSize(initialContentSize)
        window.center()
        // Autosave comes last so a saved frame wins; fixture windows use isolated names or disable autosave.
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
        }
        return window
    }

    /// Reads `--ui-test-window-content-size=<W>x<H>` from fixture launch arguments. Nil when absent or invalid.
    static func fixtureContentSize(fromArguments arguments: [String]) -> NSSize? {
        guard let argument = arguments.first(where: { $0.hasPrefix(fixtureContentSizeArgumentPrefix) }) else {
            return nil
        }
        return parseFixtureContentSize(String(argument.dropFirst(fixtureContentSizeArgumentPrefix.count)))
    }

    /// Accepts plain decimal `<W>x<H>` (lowercase x) no smaller than `minimumContentSize` on either axis.
    static func parseFixtureContentSize(_ value: String) -> NSSize? {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        let size = NSSize(width: width, height: height)
        guard size.width >= minimumContentSize.width, size.height >= minimumContentSize.height else {
            return nil
        }
        return size
    }

    // MARK: Menu and responder actions

    @objc func showPage(_ sender: NSMenuItem) {
        let pages = DashboardPage.allCases
        guard pages.indices.contains(sender.tag) else { return }
        root.select(pages[sender.tag])
    }

    @objc func showSettings(_ sender: Any?) {
        root.select(.settings)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        root.toggleSidebar(sender)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(Self.issuesURL)
    }

    @objc func openSupportPage(_ sender: Any?) {
        NSWorkspace.shared.open(SidebarViewController.supportURL)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        let integrations = dependencies.integrations
        Task { @MainActor [weak self] in
            let result = await integrations.checkForUpdates()
            guard let self else { return }
            switch result {
            case .completed:
                break
            case .unavailable(let message):
                self.presentUpdateMessage(title: "Updates Unavailable", message: message)
            case .failed(let message):
                self.presentUpdateMessage(title: "Update Check Failed", message: message)
            }
        }
    }

    private func presentUpdateMessage(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }
}
