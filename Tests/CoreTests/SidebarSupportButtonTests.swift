import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class SidebarSupportButtonTests: XCTestCase {
    private func makeSidebar(width: CGFloat, openURL: @escaping (URL) -> Void) -> SidebarViewController {
        let store = FixtureMonitoringStore(configuration: FixtureConfiguration(arguments: []))
        let sidebar = SidebarViewController(monitoringStore: store, openURL: openURL)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()
        return sidebar
    }

    func testSupportButtonOpensTheSupportPage() {
        var opened: [URL] = []
        let sidebar = makeSidebar(width: 220) { opened.append($0) }

        XCTAssertEqual(sidebar.supportButton.title, "Support Microgravity")
        XCTAssertNotNil(sidebar.supportButton.image, "The button carries the SF Symbol heart.")
        XCTAssertEqual(sidebar.supportButton.accessibilityIdentifier(), "sidebar.support")
        sidebar.supportButton.performClick(nil)

        XCTAssertEqual(opened, [URL(string: "https://rosie.run/support")!])
    }

    func testSupportButtonSitsBottomLeftAboveTheStatusFooterAtMinimumSidebarWidth() throws {
        // 200 points is the sidebar's minimum thickness in AppShellViewController.
        let sidebar = makeSidebar(width: 200) { _ in }
        let button = sidebar.supportButton
        let footer = try XCTUnwrap(sidebar.view.subviews.first { $0 is SidebarStatusFooter })

        XCTAssertEqual(button.frame.minX, 16, accuracy: 0.5, "The button aligns with the status footer's leading edge.")
        XCTAssertGreaterThanOrEqual(button.frame.minY, footer.frame.maxY, "The button sits above the status footer.")
        XCTAssertLessThan(button.frame.maxY, 120, "The button stays near the bottom of the sidebar.")
        XCTAssertLessThanOrEqual(button.frame.maxX, sidebar.view.bounds.maxX - 12, "The button fits at minimum width.")
        XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 0.5, "The title is not clipped.")
    }
}
