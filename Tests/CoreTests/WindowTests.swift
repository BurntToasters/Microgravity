import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class WindowTests: XCTestCase {
    /// Each test gets its own autosave name: the hosted app already owns the "Main" name, and
    /// AppKit refuses a name that a live window uses.
    private func uniqueAutosaveName() -> String {
        "WindowTests-\(UUID().uuidString)"
    }

    func testMainWindowOpensAtDefaultSizeAndAutosaves() {
        let name = uniqueAutosaveName()
        Self.clearSavedFrame(name)
        addTeardownBlock { Self.clearSavedFrame(name) }

        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: name)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 1280, height: 820))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 960, height: 600))
        XCTAssertEqual(window.frameAutosaveName, name)
        XCTAssertEqual(MainWindowController.frameAutosaveName, "Main")
        XCTAssertEqual(window.title, "Microgravity")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertNotNil(window.toolbar)
    }

    func testMainWindowRestoresTheAutosavedFrameOnNextLaunch() {
        let name = uniqueAutosaveName()
        Self.clearSavedFrame(name)
        addTeardownBlock { Self.clearSavedFrame(name) }

        let first = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: name)
        let firstWindow = try! XCTUnwrap(first.window)
        let frame = NSRect(x: 80, y: 90, width: 1100, height: 700)
        firstWindow.setFrame(frame, display: false)
        firstWindow.saveFrame(usingName: name)
        // Release the name so the next window can claim it, as a quit-and-relaunch would.
        firstWindow.setFrameAutosaveName("")
        firstWindow.close()

        let second = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: name)
        let secondWindow = try! XCTUnwrap(second.window)
        defer { secondWindow.close() }
        XCTAssertEqual(secondWindow.frameAutosaveName, name)
        XCTAssertEqual(secondWindow.frame.size, frame.size)
    }

    func testMainWindowKeepsCurrentFrameWhenChangingPages() {
        let name = uniqueAutosaveName()
        Self.clearSavedFrame(name)
        addTeardownBlock { Self.clearSavedFrame(name) }

        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: name)
        let window = try! XCTUnwrap(controller.window)
        defer {
            window.setFrameAutosaveName("")
            window.close()
        }
        controller.showWindow(nil)
        let userFrame = NSRect(x: 105, y: 115, width: 1100, height: 700)
        window.setFrame(userFrame, display: false)
        let root = controller.root

        root.sidebar.select(.settings)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(window.frame, userFrame,
                       "The native sidebar selection delegate must preserve the user's window frame.")

        let processesMenuItem = NSMenuItem()
        processesMenuItem.tag = try! XCTUnwrap(DashboardPage.allCases.firstIndex(of: .processes))
        controller.showPage(processesMenuItem)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(window.frame, userFrame,
                       "Menu navigation must preserve the user's current window frame too.")
    }

    func testMainWindowKeepsExactFramesAcrossNavigationAndAppearanceChanges() {
        // Sets NSApp.appearance directly so the test never writes the app defaults domain.
        let savedNSAppearance = NSApp.appearance
        addTeardownBlock { NSApp.appearance = savedNSAppearance }

        let custom = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil)
        let customWindow = try! XCTUnwrap(custom.window)
        custom.showWindow(nil)
        let customFrame = NSRect(x: 105, y: 115, width: 1100, height: 700)
        customWindow.setFrame(customFrame, display: false)
        assertFrameSurvivesInteractions(custom, expected: customFrame)
        customWindow.close()

        let minimum = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil,
                                           initialContentSize: MainWindowController.minimumContentSize)
        let minimumWindow = try! XCTUnwrap(minimum.window)
        minimum.showWindow(nil)
        settle(minimumWindow)
        XCTAssertEqual(minimumWindow.frame.size, NSSize(width: 960, height: 600))
        assertFrameSurvivesInteractions(minimum, expected: minimumWindow.frame)
        minimumWindow.close()
    }

    func testMinimumWindowReexpandsToCustomFrame() {
        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil,
                                              initialContentSize: MainWindowController.minimumContentSize)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        settle(window)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 960, height: 600))

        let expanded = NSRect(x: 105, y: 115, width: 1100, height: 700)
        window.setFrame(expanded, display: false)
        settle(window)
        XCTAssertEqual(window.frame, expanded, "Growing back from the minimum must keep the requested frame.")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 1100, height: 700))
    }

    func testFixtureContentSizeParserAcceptsValidSizesAndRejectsMalformedOrSmallValues() {
        XCTAssertEqual(MainWindowController.parseFixtureContentSize("960x600"), NSSize(width: 960, height: 600))
        XCTAssertEqual(MainWindowController.parseFixtureContentSize("1100x700"), NSSize(width: 1100, height: 700))

        for value in ["", "960", "960x", "x600", "960x600x1", "960X600", "960*600", "960.5x600",
                      " 960x600", "+960x600", "-960x600", "abcxdef", "959x600", "960x599", "600x960"] {
            XCTAssertNil(MainWindowController.parseFixtureContentSize(value), "Accepted malformed size \(value)")
        }

        XCTAssertEqual(MainWindowController.fixtureContentSize(fromArguments: [
            "--ui-test-fixtures", "--ui-test-window-content-size=1100x700"
        ]), NSSize(width: 1100, height: 700))
        XCTAssertNil(MainWindowController.fixtureContentSize(fromArguments: ["--ui-test-fixtures"]))
        XCTAssertNil(MainWindowController.fixtureContentSize(fromArguments: ["--ui-test-window-content-size=900x600"]))
    }

    func testWindowOpenedAtMinimumInitialContentSizeHasExactContentFrameAndConstraints() {
        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil,
                                              initialContentSize: MainWindowController.minimumContentSize)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        settle(window)

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 960, height: 600))
        XCTAssertEqual(window.frame.size, NSSize(width: 960, height: 600))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 960, height: 600))
    }

    /// The sidebar reads top to bottom in `DashboardPage` order, so View-menu ⌘1…⌘8 match what the user sees.
    func testSidebarListsPagesInTheViewMenuShortcutOrder() {
        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        settle(window)

        var cells: [NSTableCellView] = []
        collectNavigationCells(in: window.contentView, into: &cells)
        let listed = cells
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            .compactMap { $0.identifier?.rawValue }
        XCTAssertEqual(listed, DashboardPage.allCases.map { "navigation.item.\($0.rawValue)" })
    }

    /// Process menu actions must reach the Processes page while focus is in the sidebar, not only inside its table.
    func testProcessActionsReachTheProcessesPageFromTheSidebarAndNotFromOtherPages() {
        let controller = MainWindowController(dependencies: makeDependencies(), frameAutosaveName: nil)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        controller.root.select(.processes)
        settle(window)
        let processes = try! XCTUnwrap(controller.root.currentPageController as? ProcessesViewController)

        let sidebarOutline = try! XCTUnwrap(firstOutlineView(in: controller.root.sidebar.view))
        XCTAssertTrue(window.makeFirstResponder(sidebarOutline))
        XCTAssertTrue(window.firstResponder === sidebarOutline)

        let processActions: [Selector] = [
            #selector(ProcessesViewController.focusProcessSearch(_:)),
            #selector(ProcessesViewController.quitSelectedProcess(_:)),
            #selector(ProcessesViewController.forceQuitSelectedProcess(_:)),
            #selector(ProcessesViewController.showSelectedProcessInDetails(_:)),
            #selector(ProcessesViewController.revealSelectedProcess(_:)),
            #selector(ProcessesViewController.copySelectedPath(_:))
        ]
        for action in processActions {
            XCTAssertTrue(actionTarget(action, from: window) === processes, "\(action) should reach Processes from the sidebar")
        }
        XCTAssertNil(controller.supplementalTarget(forAction: NSSelectorFromString("copy:"), sender: nil),
                     "Unrelated actions must not be forwarded to the Processes page")

        controller.root.select(.settings)
        settle(window)
        XCTAssertNil(actionTarget(#selector(ProcessesViewController.quitSelectedProcess(_:)), from: window),
                     "Quit Process must not be forwarded while another page is shown")
    }

    /// Mirrors AppKit's lookup for a nil-target action: each responder answers if it implements the action,
    /// otherwise it may supply a target through `supplementalTarget(forAction:sender:)`.
    private func actionTarget(_ action: Selector, from window: NSWindow) -> AnyObject? {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplied = current.supplementalTarget(forAction: action, sender: nil) as AnyObject? {
                return supplied
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func firstOutlineView(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = firstOutlineView(in: subview) { return found }
        }
        return nil
    }

    private func collectNavigationCells(in view: NSView?, into cells: inout [NSTableCellView]) {
        guard let view else { return }
        if let cell = view as? NSTableCellView, cell.identifier?.rawValue.hasPrefix("navigation.item.") == true {
            cells.append(cell)
        }
        for subview in view.subviews {
            collectNavigationCells(in: subview, into: &cells)
        }
    }

    /// Runs the same frame-preserving interactions the app performs: sidebar selection, menu navigation, and appearance.
    private func assertFrameSurvivesInteractions(_ controller: MainWindowController, expected: NSRect) {
        let window = try! XCTUnwrap(controller.window)
        for page in DashboardPage.allCases {
            controller.root.select(page)
            settle(window)
            XCTAssertEqual(window.frame, expected, "Sidebar selection of \(page) changed the window frame.")
        }

        for (index, page) in DashboardPage.allCases.enumerated() {
            let menuItem = NSMenuItem()
            menuItem.tag = index
            controller.showPage(menuItem)
            settle(window)
            XCTAssertEqual(window.frame, expected, "Menu navigation to \(page) changed the window frame.")
        }

        let appearances: [(name: String, appearance: NSAppearance?)] = [
            ("light", NSAppearance(named: .aqua)),
            ("dark", NSAppearance(named: .darkAqua)),
            ("system", nil)
        ]
        for (value, appearance) in appearances {
            NSApp.appearance = appearance
            settle(window)
            XCTAssertEqual(window.frame, expected, "Switching to \(value) appearance changed the window frame.")
        }
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    private func makeDependencies() -> AppDependencies {
        let configuration = FixtureConfiguration(arguments: [])
        return AppDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: true
        )
    }

    private static func clearSavedFrame(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }
}
