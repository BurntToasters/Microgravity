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
