import AppKit
import ServiceManagement
import XCTest
@testable import Microgravity

@MainActor
final class Release011FixesTests: XCTestCase {
    // MARK: SMAppService status mapping

    func testNeverRegisteredLoginItemCanBeTurnedOn() {
        // SMAppService reports .notFound for a main app that has never been registered.
        XCTAssertEqual(NativeSystemIntegrationAPI.loginItemAvailability(.notFound), .disabled)
        XCTAssertEqual(NativeSystemIntegrationAPI.loginItemAvailability(.notRegistered), .disabled)
        XCTAssertEqual(NativeSystemIntegrationAPI.loginItemAvailability(.enabled), .enabled)
        XCTAssertEqual(NativeSystemIntegrationAPI.loginItemAvailability(.requiresApproval), .requiresApproval)
    }

    func testOnlyEnabledOrPendingHelperCountsAsRegistered() {
        XCTAssertTrue(NativeSystemIntegrationAPI.isRegistered(.enabled))
        XCTAssertTrue(NativeSystemIntegrationAPI.isRegistered(.requiresApproval))
        XCTAssertFalse(NativeSystemIntegrationAPI.isRegistered(.notRegistered))
        XCTAssertFalse(NativeSystemIntegrationAPI.isRegistered(.notFound), "A never-registered helper must not enable Remove Helper.")
    }

    func testHelperBundleCheckRequiresBothPlistAndExecutable() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("HelperCheck-\(UUID().uuidString).app")
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle) }
        XCTAssertFalse(NativeSystemIntegrationAPI.helperIsBundled(in: bundle))
        for path in NativeSystemIntegrationAPI.bundledHelperPaths {
            let url = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        XCTAssertTrue(NativeSystemIntegrationAPI.helperIsBundled(in: bundle))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/Helpers/MicrogravityHelper"))
        XCTAssertFalse(NativeSystemIntegrationAPI.helperIsBundled(in: bundle))
    }

    // MARK: Formatting

    func testZeroThroughputAndMemoryUseDigits() {
        XCTAssertFalse(UIFormat.bytesPerSecond(0).contains("Zero"))
        XCTAssertTrue(UIFormat.bytesPerSecond(0).hasPrefix("0"), UIFormat.bytesPerSecond(0))
        let memory = UIFormat.value(MetricReading(value: 0, unit: .bytes, timestamp: Date())) ?? ""
        XCTAssertFalse(memory.contains("Zero"), memory)
    }

    // MARK: Process table columns

    func testFittedNameWidthFillsTheRemainderButNeverDropsBelowMinimum() {
        XCTAssertEqual(ProcessesViewController.fittedNameWidth(visibleWidth: 1040, otherColumnWidths: 600, minimum: 160), 440)
        XCTAssertEqual(ProcessesViewController.fittedNameWidth(visibleWidth: 700, otherColumnWidths: 600, minimum: 160), 160)
    }

    func testNameColumnRefitsSoEveryColumnStaysVisibleAfterAResize() throws {
        let configuration = FixtureConfiguration(arguments: [])
        let dependencies = AppDependencies(monitoringStore: FixtureMonitoringStore(configuration: configuration),
                                           processActions: FixtureProcessActioner(configuration: configuration),
                                           integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true)
        let name = "Release011-\(UUID().uuidString)"
        let controller = MainWindowController(dependencies: dependencies, frameAutosaveName: name)
        let window = try XCTUnwrap(controller.window)
        defer {
            window.setFrameAutosaveName("")
            window.close()
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
        controller.showWindow(nil)
        settle(window)
        let outline = try XCTUnwrap(findOutline(in: try XCTUnwrap(window.contentView)))
        let nameColumn = try XCTUnwrap(outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("process.column.name")))

        // A layout saved from a wider window: Name alone pushes the metric columns out of view.
        nameColumn.width = 900
        XCTAssertGreaterThan(outline.frame.width, try XCTUnwrap(outline.enclosingScrollView).contentView.bounds.width)

        var frame = window.frame
        frame.size.width -= 40
        window.setFrame(frame, display: true)
        settle(window)

        let clip = try XCTUnwrap(outline.enclosingScrollView).contentView.bounds.width
        let total = outline.tableColumns.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width }
        XCTAssertLessThanOrEqual(total, clip + 0.5, "Visible columns must fit the table after a resize.")
        XCTAssertGreaterThanOrEqual(nameColumn.width, nameColumn.minWidth)
    }

    func testUserDraggedNameWidthSurvivesSampleUpdates() throws {
        let configuration = FixtureConfiguration(arguments: [])
        let store = FixtureMonitoringStore(configuration: configuration)
        let controller = ProcessesViewController(dependencies: PageDependencies(
            monitoringStore: store,
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 700))
        settle(window)
        let outline = try XCTUnwrap(findOutline(in: controller.view))
        let nameColumn = try XCTUnwrap(outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ProcessColumn.name.rawValue)))
        let snapshot = try XCTUnwrap(store.latestSnapshot)
        // The first snapshot can change column visibility (GPU, Network) and refit Name once; drag after that.
        controller.update(snapshot: snapshot)
        settle(window)

        nameColumn.width = nameColumn.minWidth + 37
        let dragged = nameColumn.width
        for _ in 0..<3 {
            controller.update(snapshot: snapshot)
        }
        settle(window)
        XCTAssertEqual(nameColumn.width, dragged, accuracy: 0.5, "Sampling must not reset a Name width the user dragged.")
    }

    // MARK: Smaller layout fixes

    func testCPUHeaderExplainsThatProcessCPUIsAShareOfAllCores() throws {
        let configuration = FixtureConfiguration(arguments: [])
        let controller = ProcessesViewController(dependencies: PageDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true))
        controller.loadViewIfNeeded()
        let outline = try XCTUnwrap(findOutline(in: controller.view))
        let cpu = try XCTUnwrap(outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ProcessColumn.cpu.rawValue)))
        XCTAssertEqual(cpu.headerToolTip, "Share of total CPU capacity across all cores. 100% means every core is busy.")
    }

    func testLongProcessNamesKeepTheirEndAndShowTheFullNameOnHover() throws {
        let cell = ProcessNameCellView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        let name = "com.apple.Virtualization.VirtualMachine"
        cell.configure(ProcessNameContent(title: name, isGroup: true, bundlePath: nil, accessibilityID: "process.group.test"))
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cell.toolTip, name)
    }

    func testProcessHeadersArePaddedLikeTheirCells() throws {
        let configuration = FixtureConfiguration(arguments: [])
        let controller = ProcessesViewController(dependencies: PageDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true))
        controller.loadViewIfNeeded()
        let outline = try XCTUnwrap(findOutline(in: controller.view))
        for column in outline.tableColumns {
            let header = try XCTUnwrap(column.headerCell as? PaddedTableHeaderCell, column.identifier.rawValue)
            let bounds = NSRect(x: 0, y: 0, width: 100, height: 24)
            let title = header.titleRect(forBounds: bounds)
            XCTAssertGreaterThanOrEqual(title.minX, PaddedTableHeaderCell.horizontalInset - 0.5)
            XCTAssertLessThanOrEqual(title.maxX, bounds.maxX - PaddedTableHeaderCell.horizontalInset + 0.5)
        }
    }

    func testSettingsLabelsLineUpAcrossCardsAndStayPutWhenAppearanceChanges() throws {
        let settings = SettingsViewController(dependencies: PageDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: FixtureConfiguration(arguments: [])),
            processActions: UnusedReleaseActioner(),
            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = settings
        window.setContentSize(NSSize(width: 1040, height: 900))
        settle(window)

        func labelEdges() -> [CGFloat] {
            settings.formGrids.flatMap { grid in
                (0..<grid.numberOfRows).compactMap { row -> CGFloat? in
                    guard let label = grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField,
                          !label.stringValue.isEmpty else { return nil }
                    return label.convert(label.bounds, to: nil).maxX.rounded()
                }
            }
        }
        let before = labelEdges()
        XCTAssertGreaterThanOrEqual(before.count, 6)
        XCTAssertEqual(Set(before).count, 1, "Every form label ends at the same x: \(before)")

        let popUp = try XCTUnwrap(settings.formGrids.first?.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSPopUpButton)
        popUp.selectItem(at: (popUp.indexOfSelectedItem + 1) % popUp.numberOfItems)
        settle(window)
        XCTAssertEqual(labelEdges(), before, "Changing the value must not move the labels.")
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView, outline.accessibilityIdentifier() == "process.table" { return outline }
        for subview in view.subviews {
            if let found = findOutline(in: subview) { return found }
        }
        return nil
    }
}

private struct UnusedReleaseActioner: ProcessActioning {
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        ProcessActionResult(identity: identity, force: force, outcome: .rejected(.helperUnavailable, detail: nil))
    }
}
