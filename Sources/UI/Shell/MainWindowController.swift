import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 1280, height: 820)
    static let minimumContentSize = NSSize(width: 960, height: 600)
    nonisolated static let frameAutosaveName = "Main"

    private let dependencies: AppDependencies
    private let root: RootViewController
    private let mainToolbar: MainToolbar

    init(dependencies: AppDependencies, frameAutosaveName: String = MainWindowController.frameAutosaveName) {
        self.dependencies = dependencies
        let root = RootViewController(dependencies: dependencies)
        let window = Self.makeWindow(root: root, frameAutosaveName: frameAutosaveName)
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
    private static func makeWindow(root: RootViewController, frameAutosaveName: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
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
        window.setContentSize(defaultContentSize)
        window.center()
        // Returns false if another live window already owns this name; a saved frame is restored only when it succeeds.
        window.setFrameAutosaveName(frameAutosaveName)
        return window
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
