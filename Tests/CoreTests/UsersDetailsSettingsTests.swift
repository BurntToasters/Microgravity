import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class UsersDetailsSettingsTests: XCTestCase {
    func testHelperStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.helper(.available), .positive)
        XCTAssertEqual(IntegrationStatusTone.helper(.notConfigured), .neutral)
        XCTAssertEqual(IntegrationStatusTone.helper(.requiresApproval), .attention)
        XCTAssertEqual(IntegrationStatusTone.helper(.unavailable("Not installed")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.helper(.failed("Handshake failed")), .failure)
    }

    func testLoginItemStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.loginItem(.enabled), .positive)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.disabled), .neutral)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.requiresApproval), .attention)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.unavailable("Unsupported")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.failed("Registration failed")), .failure)
    }

    func testUpdateStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.updates(.current), .positive)
        XCTAssertEqual(IntegrationStatusTone.updates(.idle), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.checking), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.updateAvailable(version: "0.2.0")), .attention)
        XCTAssertEqual(IntegrationStatusTone.updates(.unavailable("Not configured")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.failed("Feed unreachable")), .failure)
    }

    func testProcessesGroupByOwnerUIDInOnePass() {
        let processes = [
            makeProcess(pid: 10, uid: 501),
            makeProcess(pid: 11, uid: 0),
            makeProcess(pid: 12, uid: 501)
        ]

        let grouped = UserAggregation.processesByUID(processes)

        XCTAssertEqual(grouped[501]?.map(\.id.pid), [10, 12])
        XCTAssertEqual(grouped[0]?.map(\.id.pid), [11])
        XCTAssertNil(grouped[502])
    }

    func testCurrentUserBadgeIsOptionalAndSeparateFromBareNameSortValue() {
        XCTAssertEqual(UserAggregation.currentUserBadge(isCurrentUser: true), "You")
        XCTAssertNil(UserAggregation.currentUserBadge(isCurrentUser: false))
    }

    func testAppBundlePathUsesOutermostBundleOrNil() {
        XCTAssertEqual(DetailsPresentation.appBundlePath(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari"),
                       "/Applications/Safari.app")
        XCTAssertEqual(DetailsPresentation.appBundlePath(
            forExecutable: "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                       "/Applications/Chrome.app")
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: "/usr/bin/env"))
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: ""))
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: nil))
    }

    func testSettingsHelperCaptionWrapsInsideFormAtMinimumWindowSize() {
        let caption = "Lets you quit processes owned by other standard users. System and root processes stay protected."
        let controller = MainWindowController(dependencies: makeAppDependencies(), frameAutosaveName: nil)
        let window = try! XCTUnwrap(controller.window)
        defer { window.close() }
        window.setContentSize(MainWindowController.minimumContentSize)
        let contentView = try! XCTUnwrap(window.contentView)
        let contentWidthBeforeLayout = window.contentLayoutRect.width

        controller.root.select(.settings)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.contentLayoutRect.width, contentWidthBeforeLayout, accuracy: 0.5,
                       "Settings layout must not widen or shrink the window.")
        let field = try! XCTUnwrap(labelField(stringValue: caption, in: contentView))
        XCTAssertEqual(field.lineBreakMode, .byWordWrapping,
                       "A truncating line break mode forces one line, so the helper caption would be ellipsized.")
        let fieldFrame = contentView.convert(field.bounds, from: field)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, contentView.bounds.maxX + 0.5,
                                 "The caption must stay inside the window at minimum width.")
        let fullTextHeight = try! XCTUnwrap(field.cell).cellSize(
            forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)).height
        XCTAssertLessThanOrEqual(fullTextHeight, field.frame.height + 0.5,
                                 "The caption frame must be tall enough to show every wrapped line.")
    }

    func testSettingsStartsAtTopAtMinimumAndDefaultWindowSizes() throws {
        for size in [MainWindowController.minimumContentSize, NSSize(width: 1280, height: 820)] {
            let label = "\(Int(size.width))x\(Int(size.height))"
            let controller = MainWindowController(dependencies: makeAppDependencies(), frameAutosaveName: nil)
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            window.setContentSize(size)
            let contentView = try XCTUnwrap(window.contentView)
            let contentSizeBeforeSelect = window.contentLayoutRect.size

            controller.root.select(.settings)
            contentView.layoutSubtreeIfNeeded()

            XCTAssertEqual(window.contentLayoutRect.width, contentSizeBeforeSelect.width, accuracy: 0.5,
                           "Settings must not change the window width at \(label).")
            XCTAssertEqual(window.contentLayoutRect.height, contentSizeBeforeSelect.height, accuracy: 0.5,
                           "Settings must not change the window height at \(label).")

            let scroll = try XCTUnwrap(allDescendants(of: contentView).compactMap { $0 as? NSScrollView }.first {
                labelField(stringValue: "Appearance", in: $0) != nil && labelField(stringValue: "Settings", in: $0) != nil
            }, "Settings scroll view missing at \(label)")
            let clip = scroll.contentView
            let visible = clip.documentVisibleRect
            let appearance = try XCTUnwrap(labelField(stringValue: "Appearance", in: scroll))
            let header = try XCTUnwrap(labelField(stringValue: "Settings", in: scroll))

            let appearanceFrame = clip.convert(appearance.bounds, from: appearance)
            XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(appearanceFrame),
                          "The Appearance card must be fully visible when Settings opens at \(label); "
                          + "visible \(visible), card \(appearanceFrame).")

            // Distance from the visible top edge to the header, in the clip view's own (possibly flipped) space.
            let headerFrame = clip.convert(header.bounds, from: header)
            let distanceFromTop = clip.isFlipped ? headerFrame.minY - visible.minY : visible.maxY - headerFrame.maxY
            XCTAssertLessThanOrEqual(distanceFromTop, PageLayout.topInset + 4,
                                     "The Settings header must sit at the top of the page at \(label), not pushed down.")

            // Each section card keeps its natural height instead of stretching to fill the clip view.
            let content = try XCTUnwrap(header.superview?.superview as? NSStackView)
            let cards = Array(content.arrangedSubviews.dropFirst())
            XCTAssertEqual(cards.count, 3, "Settings must show three section cards at \(label).")
            for card in cards {
                XCTAssertEqual(card.frame.height, card.fittingSize.height, accuracy: 1,
                               "A Settings card must not stretch past its content at \(label).")
            }
        }
    }

    func testDetailsCellsShowTheValueForTheirColumnAndCPUSortsNumerically() throws {
        let busy = makeDetailsProcess(pid: 4242, name: "Sample", cpu: 33)
        let alpha = makeDetailsProcess(pid: 1001, name: "Alpha", cpu: 9)
        let zed = makeDetailsProcess(pid: 1002, name: "Zed", cpu: 10)
        let controller = DetailsViewController(autosaveName: nil)
        _ = controller.view
        controller.update(snapshot: makeDetailsSnapshot(processes: [busy, alpha, zed]))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        controller.view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(allDescendants(of: controller.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityIdentifier() == "details.table" })

        let rowID = "details.process.\(busy.id.pid)"
        let row = try XCTUnwrap(rowIndex(of: rowID, in: table))
        let network = try XCTUnwrap(busy.advancedMetrics[.processNetwork])
        let gpu = try XCTUnwrap(busy.advancedMetrics[.processGPUTime])
        let path = try XCTUnwrap(busy.executablePath)
        XCTAssertEqual(UIFormat.metric(busy.cpuPercent), "33%")
        let expected: [(key: String, text: String)] = [
            ("name", "Sample"),
            ("pid", "4242"),
            ("owner", UIFormat.ownerName(busy.ownerUID)),
            ("parent", "1"),
            ("cpu", UIFormat.metric(busy.cpuPercent)),
            ("memory", UIFormat.metric(busy.memoryBytes)),
            ("disk", "R \(UIFormat.metric(busy.diskReadBytesPerSecond)) · W \(UIFormat.metric(busy.diskWriteBytesPerSecond))"),
            ("network", UIFormat.metric(network)),
            ("gpu", UIFormat.metric(gpu)),
            ("path", path)
        ]
        for (key, text) in expected {
            let label = try XCTUnwrap(cellLabel(in: table, row: row, key: key), "missing cell \(key)")
            XCTAssertEqual(label.accessibilityIdentifier(), "\(rowID).\(key)")
            XCTAssertEqual(label.stringValue, text, "cell \(key) shows the wrong value")
        }

        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: true)]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: [])
        var namesInOrder: [String] = []
        var cpuTextsInOrder: [String] = []
        for index in 0..<table.numberOfRows {
            namesInOrder.append(try XCTUnwrap(cellLabel(in: table, row: index, key: "name")).stringValue)
            cpuTextsInOrder.append(try XCTUnwrap(cellLabel(in: table, row: index, key: "cpu")).stringValue)
        }
        XCTAssertEqual(namesInOrder, ["Alpha", "Zed", "Sample"], "CPU sorts by numeric value, not text")
        XCTAssertEqual(cpuTextsInOrder, [UIFormat.metric(alpha.cpuPercent), UIFormat.metric(zed.cpuPercent),
                                         UIFormat.metric(busy.cpuPercent)])
    }

    /// The row whose first-column label carries `rowID.name`.
    private func rowIndex(of rowID: String, in table: NSTableView) -> Int? {
        (0..<table.numberOfRows).first { index in
            cellLabel(in: table, row: index, key: "name")?.accessibilityIdentifier() == "\(rowID).name"
        }
    }

    /// The value label of one cell, found by its `<rowID>.<key>` accessibility identifier.
    private func cellLabel(in table: NSTableView, row: Int, key: String) -> NSTextField? {
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView else {
            return nil
        }
        return allDescendants(of: cell).compactMap { $0 as? NSTextField }.first { field in
            field.accessibilityIdentifier().hasSuffix(".\(key)")
        }
    }

    private func makeDetailsSnapshot(processes: [ProcessSnapshot]) -> MonitoringSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        return MonitoringSnapshot(timestamp: timestamp, system: base.system, processes: processes,
                                  processGroups: [], startupItems: [], services: [], users: [],
                                  discoveryCoverage: [:], capabilities: [:])
    }

    private func makeDetailsProcess(pid: Int32, name: String, cpu: Double) -> ProcessSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ProcessIdentity(pid: pid,
                                       startTime: ProcessStartTime(secondsSinceEpoch: Int64(pid), microseconds: 0))
        let parent = ProcessIdentity(pid: 1, startTime: ProcessStartTime(secondsSinceEpoch: 1, microseconds: 0))
        return ProcessSnapshot(
            id: identity, parentIdentity: parent, childIdentities: [], name: name,
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)", ownerUID: 501, isCurrentUser: false,
            cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: timestamp),
            memoryBytes: MetricReading(value: 1_500_000_000, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: MetricReading(value: 4_096, unit: .bytesPerSecond, timestamp: timestamp),
            diskWriteBytesPerSecond: MetricReading(value: 8_192, unit: .bytesPerSecond, timestamp: timestamp),
            diskReadTotalBytes: MetricReading(value: 1, unit: .bytes, timestamp: timestamp),
            diskWriteTotalBytes: MetricReading(value: 1, unit: .bytes, timestamp: timestamp),
            advancedMetrics: [
                .processNetwork: MetricReading(value: 2_048, unit: .bytesPerSecond, timestamp: timestamp),
                .processGPUTime: MetricReading(value: 1.5, unit: .seconds, timestamp: timestamp)
            ])
    }

    private func makeAppDependencies() -> AppDependencies {
        let configuration = FixtureConfiguration(arguments: [])
        return AppDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: true
        )
    }

    private func labelField(stringValue: String, in root: NSView) -> NSTextField? {
        ([root] + allDescendants(of: root)).compactMap { $0 as? NSTextField }.first { $0.stringValue == stringValue }
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allDescendants(of: $0) }
    }

    private func makeProcess(pid: Int32, uid: UInt32) -> ProcessSnapshot {
        let timestamp = Date(timeIntervalSince1970: 0)
        let identity = ProcessIdentity(pid: pid,
                                       startTime: ProcessStartTime(secondsSinceEpoch: Int64(pid), microseconds: 0))
        let percent = MetricReading(value: 0, unit: .percent, timestamp: timestamp)
        let bytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        return ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [], name: "process-\(pid)",
            executablePath: nil, ownerUID: uid, isCurrentUser: false, cpuPercent: percent,
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes)
    }
}
