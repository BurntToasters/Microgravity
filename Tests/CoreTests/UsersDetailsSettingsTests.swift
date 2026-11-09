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
            // The version footer sits after the cards in the same stack but is not a card.
            let cards = Array(content.arrangedSubviews.dropFirst()).filter { $0.accessibilityIdentifier() != "settings.version" }
            XCTAssertEqual(cards.count, 5, "Settings must show five section cards (Appearance, Colors, Sampling, Integrations, Reset) at \(label).")
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

    private func makeDetailsSnapshot(processes: [ProcessSnapshot], users: [UserSessionSnapshot] = [],
                                     capabilities: [MetricKind: MetricAvailability] = [:]) -> MonitoringSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        return MonitoringSnapshot(timestamp: timestamp, system: base.system, processes: processes,
                                  processGroups: [], startupItems: [], services: [], users: users,
                                  discoveryCoverage: [:], capabilities: capabilities)
    }

    /// The table cell's view for `rowID`'s `key` column, not just its label.
    private func cellView(in table: NSTableView, row: Int, key: String) -> NSTableCellView? {
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }) else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    /// True when the cell shows a visible marker image (partial or unavailable).
    private func hasMarker(_ cell: NSView) -> Bool {
        allDescendants(of: cell).compactMap { $0 as? NSImageView }.contains { !$0.isHidden && $0.image != nil }
    }

    /// The status banner that holds the text field with `identifier`.
    private func bannerView(identifier: String, in root: NSView) -> StatusBannerView? {
        guard let field = allDescendants(of: root).compactMap({ $0 as? NSTextField })
            .first(where: { $0.accessibilityIdentifier() == identifier }) else { return nil }
        var ancestor: NSView? = field.superview
        while let view = ancestor {
            if let banner = view as? StatusBannerView { return banner }
            ancestor = view.superview
        }
        return nil
    }

    private func button(titled title: String, in root: NSView) -> NSButton? {
        allDescendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    private func makeUsersTable(_ controller: UsersViewController) throws -> NSTableView {
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        return try XCTUnwrap(allDescendants(of: controller.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityIdentifier() == "users.table" })
    }

    func testPartialAndUnavailableDetailsCellsShowShortValuesAndKeepTheReasonInTheTooltip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ProcessIdentity(pid: 77, startTime: ProcessStartTime(secondsSinceEpoch: 77, microseconds: 0))
        let partial = ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [], name: "Partial", executablePath: nil,
            ownerUID: 501, isCurrentUser: false,
            cpuPercent: MetricReading(value: 12, unit: .percent, timestamp: timestamp,
                                      detail: "Partial: 3 of 10 members unavailable", isPartial: true),
            memoryBytes: MetricReading(value: 1_024, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .permissionDenied),
            diskWriteBytesPerSecond: MetricReading(value: 2_048, unit: .bytesPerSecond, timestamp: timestamp),
            diskReadTotalBytes: MetricReading(value: 1, unit: .bytes, timestamp: timestamp),
            diskWriteTotalBytes: MetricReading(value: 1, unit: .bytes, timestamp: timestamp),
            advancedMetrics: [.processNetwork: MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                             reason: .notCollected,
                                                             detail: HelperSamplingClient.unavailableError)])
        let controller = DetailsViewController(autosaveName: nil)
        _ = controller.view
        controller.update(snapshot: makeDetailsSnapshot(processes: [partial], capabilities: [
            .processes: MetricAvailability(available: true),
            // The capability itself is available (the column stays visible); this process's reading is missing.
            .processNetwork: MetricAvailability(available: true)
        ]))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        controller.view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(allDescendants(of: controller.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityIdentifier() == "details.table" })
        let row = try XCTUnwrap(rowIndex(of: "details.process.77", in: table))

        // Partial CPU: the number alone in the cell, the reason in the tooltip, a marker, and a full spoken description.
        let cpu = try XCTUnwrap(cellLabel(in: table, row: row, key: "cpu"))
        XCTAssertEqual(cpu.stringValue, UIFormat.value(partial.cpuPercent))
        XCTAssertFalse(cpu.stringValue.contains("partial"))
        XCTAssertEqual(cpu.toolTip, "Partial value. Partial: 3 of 10 members unavailable")
        XCTAssertEqual(cpu.accessibilityLabel(), "12%, partial, Partial: 3 of 10 members unavailable")
        let cpuCell = try XCTUnwrap(cellView(in: table, row: row, key: "cpu"))
        let memoryCell = try XCTUnwrap(cellView(in: table, row: row, key: "memory"))
        XCTAssertTrue(hasMarker(cpuCell))
        XCTAssertFalse(hasMarker(memoryCell), "a complete value has no marker")

        // Partly unavailable disk pair: the measured half stays visible and the missing half is "—".
        let disk = try XCTUnwrap(cellLabel(in: table, row: row, key: "disk"))
        XCTAssertEqual(disk.stringValue, "R — · W \(UIFormat.bytesPerSecond(2_048))")
        XCTAssertTrue(disk.toolTip?.hasPrefix("R: ") == true, disk.toolTip ?? "no tooltip")
        let diskCell = try XCTUnwrap(cellView(in: table, row: row, key: "disk"))
        XCTAssertTrue(hasMarker(diskCell))

        // Unavailable network: "—" with the reason in the tooltip; the helper code is spelled out for people.
        let network = try XCTUnwrap(cellLabel(in: table, row: row, key: "network"))
        XCTAssertEqual(network.stringValue, "—")
        XCTAssertEqual(network.toolTip, "Not collected · the optional helper is not available")
        let networkCell = try XCTUnwrap(cellView(in: table, row: row, key: "network"))
        XCTAssertTrue(hasMarker(networkCell))
    }

    func testDetailsMissingHelperIsInformationWithASetupButton() throws {
        let controller = DetailsViewController(autosaveName: nil)
        _ = controller.view
        controller.update(snapshot: makeDetailsSnapshot(processes: [makeDetailsProcess(pid: 9, name: "Plain", cpu: 1)], capabilities: [
            .processes: MetricAvailability(available: true),
            .processNetwork: MetricAvailability(available: false, reason: .collectionFailed,
                                                detail: HelperSamplingClient.unavailableError),
            // Per-process GPU is never collected; it must not be reported as a problem.
            .processGPUTime: MetricAvailability(available: false, reason: .unsupported,
                                                detail: "Per-process GPU time is not collected.")
        ]))

        let banner = try XCTUnwrap(bannerView(identifier: "details.capability-state", in: controller.view))
        XCTAssertEqual(banner.style, .info, "a missing optional helper is information, not a warning")
        XCTAssertTrue(banner.textField.stringValue.contains("needs the optional helper"), banner.textField.stringValue)
        XCTAssertFalse(banner.textField.stringValue.contains("GPU"))
        let setUp = try XCTUnwrap(button(titled: "Set Up Helper…", in: banner))
        XCTAssertFalse(setUp.isHidden)

        controller.update(snapshot: makeDetailsSnapshot(processes: [], capabilities: [
            .processes: MetricAvailability(available: false, reason: .permissionDenied, detail: "Process list denied")
        ]))
        let warning = try XCTUnwrap(bannerView(identifier: "details.capability-state", in: controller.view))
        XCTAssertEqual(warning.style, .warning, "unavailable processes are a warning")
        XCTAssertTrue(button(titled: "Set Up Helper…", in: warning)?.isHidden ?? true, "no setup offer when processes are missing")
    }

    func testUsersAggregatesShowUnitsWhenEmptyAndExplainUnavailableData() throws {
        let users = [UserSessionSnapshot(uid: 501, shortName: "alice", isCurrentUser: false, loginSessions: [])]
        let controller = UsersViewController()
        let table = try makeUsersTable(controller)
        controller.update(snapshot: makeDetailsSnapshot(processes: [], users: users, capabilities: [
            .processes: MetricAvailability(available: true),
            .userSessions: MetricAvailability(available: true)
        ]))
        let row = 0
        XCTAssertEqual(try XCTUnwrap(cellLabel(in: table, row: row, key: "process-count")).stringValue, "0")
        XCTAssertEqual(try XCTUnwrap(cellLabel(in: table, row: row, key: "cpu")).stringValue, "0%",
                       "a measured zero keeps its unit")
        XCTAssertEqual(try XCTUnwrap(cellLabel(in: table, row: row, key: "memory")).stringValue,
                       UIFormat.value(MetricReading(value: 0, unit: .bytes, timestamp: Date())),
                       "a measured zero keeps its unit, as every other byte value does")
        XCTAssertEqual(try XCTUnwrap(bannerView(identifier: "users.discovery-state", in: controller.view)).style, .info)

        controller.update(snapshot: makeDetailsSnapshot(processes: [], users: users, capabilities: [
            .processes: MetricAvailability(available: false, reason: .permissionDenied),
            .userSessions: MetricAvailability(available: true)
        ]))
        let cpu = try XCTUnwrap(cellLabel(in: table, row: row, key: "cpu"))
        XCTAssertEqual(cpu.stringValue, "—")
        XCTAssertEqual(cpu.toolTip, "Permission denied")
        XCTAssertEqual(try XCTUnwrap(cellLabel(in: table, row: row, key: "process-count")).stringValue, "—")
        XCTAssertEqual(try XCTUnwrap(bannerView(identifier: "users.discovery-state", in: controller.view)).style, .warning)
    }

    func testUsersBannerPluralizesRecordCount() throws {
        let available: [MetricKind: MetricAvailability] = [
            .processes: MetricAvailability(available: true),
            .userSessions: MetricAvailability(available: true)
        ]
        let alice = UserSessionSnapshot(uid: 501, shortName: "alice", isCurrentUser: false, loginSessions: [])
        let bob = UserSessionSnapshot(uid: 502, shortName: "bob", isCurrentUser: false, loginSessions: [])
        let controller = UsersViewController()
        _ = try makeUsersTable(controller)

        func bannerText() throws -> String {
            let field = try XCTUnwrap(allDescendants(of: controller.view).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "users.discovery-state" })
            return field.stringValue
        }
        controller.update(snapshot: makeDetailsSnapshot(processes: [], users: [alice], capabilities: available))
        let singular = try bannerText()
        XCTAssertTrue(singular.hasPrefix("1 user record · updated"), singular)
        controller.update(snapshot: makeDetailsSnapshot(processes: [], users: [alice, bob], capabilities: available))
        let plural = try bannerText()
        XCTAssertTrue(plural.hasPrefix("2 user records · updated"), plural)
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

    func testUsersIncludeEveryProcessOwnerWithoutDuplicatingSessionUsers() {
        let me = UserSessionSnapshot(uid: 501, shortName: "me", isCurrentUser: true, loginSessions: ["console"])
        let users = UserAggregation.users(sessions: [me], processOwners: [0, 88, 501],
                                          name: { $0 == 0 ? "root" : "_windowserver" })
        XCTAssertEqual(users.map(\.uid), [501, 0, 88])
        XCTAssertEqual(users.first(where: { $0.uid == 0 })?.shortName, "root")
        XCTAssertEqual(users.first(where: { $0.uid == 0 })?.loginSessions, [])
        XCTAssertFalse(users.first(where: { $0.uid == 88 })?.isCurrentUser ?? true)
    }

    func testQuitControlsAreDisabledForProcessesTheControllersAlwaysRefuse() {
        var root = makeProcess(pid: 400, uid: 0, path: "/Applications/Tool.app/Contents/MacOS/Tool")
        XCTAssertTrue(ProcessesViewController.isProtectedFromQuit(root))
        root = makeProcess(pid: 401, uid: 501, path: "/System/Library/CoreServices/Agent")
        XCTAssertTrue(ProcessesViewController.isProtectedFromQuit(root), "protected system location")
        XCTAssertTrue(ProcessesViewController.isProtectedFromQuit(makeProcess(pid: 402, uid: 501)),
                      "an unreadable path cannot rule out a system process")
        XCTAssertFalse(ProcessesViewController.isProtectedFromQuit(
            makeProcess(pid: 403, uid: 501, path: "/Applications/Notes.app/Contents/MacOS/Notes")))
        XCTAssertFalse(ProcessesViewController.isProtectedFromQuit(
            makeProcess(pid: 404, uid: 502, path: "/Users/other/bin/tool")), "another user's process goes to the helper")
    }

    func testHelperFailureCodesBecomeReadableText() {
        XCTAssertEqual(NativeAdvancedMetricsCollector.describe(helperError: "helperUnavailable"),
                       NativeAdvancedMetricsCollector.helperRequiredDetail)
        XCTAssertEqual(NativeAdvancedMetricsCollector.describe(helperError: "timedOut"),
                       "The helper did not respond in time.")
        XCTAssertEqual(NativeAdvancedMetricsCollector.describe(helperError: "somethingNew"), "somethingNew")
        XCTAssertNil(NativeAdvancedMetricsCollector.describe(helperError: nil))
    }

    private func makeProcess(pid: Int32, uid: UInt32, path: String? = nil) -> ProcessSnapshot {
        let timestamp = Date(timeIntervalSince1970: 0)
        let identity = ProcessIdentity(pid: pid,
                                       startTime: ProcessStartTime(secondsSinceEpoch: Int64(pid), microseconds: 0))
        let percent = MetricReading(value: 0, unit: .percent, timestamp: timestamp)
        let bytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        return ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [], name: "process-\(pid)",
            executablePath: path, ownerUID: uid, isCurrentUser: false, cpuPercent: percent,
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes)
    }
}
