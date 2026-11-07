import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class UIStateTests: XCTestCase {
    func testProcessRootChildKeepsItsRowKindAcrossRefreshAndSortThenClearsOnCollapse() {
        let (dependencies, store, _) = makeDependencies()
        let controller = ProcessesViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        controller.update(snapshot: snapshot)

        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSTableView?)
        let groupCell = try! XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let disclosure = try! XCTUnwrap(view(withIdentifier: "process.group.toggle.fixture-editor", in: groupCell) as NSButton?)
        disclosure.performClick(nil)

        let rootRow = try! XCTUnwrap((0..<table.numberOfRows).first { row in
            let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
            return textFields(in: cell).contains { $0.stringValue == "Fixture Editor Renderer" }
        })
        table.selectRowIndexes(IndexSet(integer: rootRow), byExtendingSelection: false)
        XCTAssertTrue(textField(withIdentifier: "process.selection.identity", in: controller.view)?.stringValue.contains("pid=410") == true)

        controller.update(snapshot: copy(snapshot, timestamp: snapshot.timestamp.addingTimeInterval(1)))
        XCTAssertEqual(selectedName(in: controller, table: table), "Fixture Editor Renderer")

        let oldDescriptors = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: "process.column.pid", ascending: false)]
        controller.tableView(table, sortDescriptorsDidChange: oldDescriptors)
        XCTAssertEqual(selectedName(in: controller, table: table), "Fixture Editor Renderer")

        let editorGroupRow = try! XCTUnwrap((0..<table.numberOfRows).first { row in
            let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
            return textFields(in: cell).contains { $0.stringValue == "Fixture Editor" }
        })
        let editorGroupCell = try! XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns[0], row: editorGroupRow))
        let collapse = try! XCTUnwrap(view(withIdentifier: "process.group.toggle.fixture-editor", in: editorGroupCell) as NSButton?)
        collapse.performClick(nil)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertEqual(textField(withIdentifier: "process.selection.identity", in: controller.view)?.stringValue, "No process selected")
    }

    func testProcessPIDReuseClearsSelectionByFullIdentity() {
        let (dependencies, store, _) = makeDependencies()
        let controller = ProcessesViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        controller.update(snapshot: snapshot)
        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSTableView?)
        let groupCell = try! XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns[0], row: 0))
        try! XCTUnwrap(view(withIdentifier: "process.group.toggle.fixture-editor", in: groupCell) as NSButton?).performClick(nil)

        let rendererRow = try! XCTUnwrap((0..<table.numberOfRows).first { row in
            let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
            return textFields(in: cell).contains { $0.stringValue == "Fixture Renderer Worker" }
        })
        table.selectRowIndexes(IndexSet(integer: rendererRow), byExtendingSelection: false)
        let oldRenderer = try! XCTUnwrap(snapshot.processes.first { $0.id.pid == 411 })
        let replacementID = ProcessIdentity(pid: oldRenderer.id.pid,
                                            startTime: ProcessStartTime(secondsSinceEpoch: oldRenderer.id.startTime.secondsSinceEpoch + 100,
                                                                        microseconds: oldRenderer.id.startTime.microseconds))
        let replacement = ProcessSnapshot(
            id: replacementID, parentIdentity: oldRenderer.parentIdentity,
            childIdentities: oldRenderer.childIdentities, name: oldRenderer.name,
            executablePath: oldRenderer.executablePath, ownerUID: oldRenderer.ownerUID,
            isCurrentUser: oldRenderer.isCurrentUser, cpuPercent: oldRenderer.cpuPercent,
            memoryBytes: oldRenderer.memoryBytes, diskReadBytesPerSecond: oldRenderer.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: oldRenderer.diskWriteBytesPerSecond, diskReadTotalBytes: oldRenderer.diskReadTotalBytes,
            diskWriteTotalBytes: oldRenderer.diskWriteTotalBytes, advancedMetrics: oldRenderer.advancedMetrics,
            parentPID: oldRenderer.parentPID, parentExecutablePath: oldRenderer.parentExecutablePath
        )
        let reusedGroup = try! XCTUnwrap(snapshot.processGroups.first { $0.id.pid == 410 })
        let updatedGroup = ProcessGroupSnapshot(
            id: reusedGroup.id, title: reusedGroup.title, ownerUID: reusedGroup.ownerUID,
            executablePath: reusedGroup.executablePath, association: reusedGroup.association,
            historyIdentity: reusedGroup.historyIdentity,
            members: reusedGroup.members.map { $0 == oldRenderer.id ? replacementID : $0 },
            cpuPercent: reusedGroup.cpuPercent, memoryBytes: reusedGroup.memoryBytes,
            diskReadBytesPerSecond: reusedGroup.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: reusedGroup.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: reusedGroup.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: reusedGroup.networkTransmitBytesPerSecond
        )
        let replacementSnapshot = copy(
            snapshot, timestamp: snapshot.timestamp.addingTimeInterval(1),
            processes: snapshot.processes.map { $0.id == oldRenderer.id ? replacement : $0 },
            processGroups: snapshot.processGroups.map { $0.id == reusedGroup.id ? updatedGroup : $0 }
        )

        controller.update(snapshot: replacementSnapshot)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertEqual(textField(withIdentifier: "process.selection.identity", in: controller.view)?.stringValue, "No process selected")
    }

    func testProcessGroupAdvancedRowsKeepPartialValuesDetailsAndSortByNumericLowerBound() {
        let (dependencies, store, _) = makeDependencies()
        let controller = ProcessesViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        let timestamp = snapshot.timestamp
        let networkDetail = "network capture omitted one contributor"
        let gpuDetail = "GPU capture omitted one contributor"

        let processes = snapshot.processes.map { process -> ProcessSnapshot in
            var advanced = process.advancedMetrics
            switch process.id.pid {
            case 410:
                advanced[.processNetwork] = MetricReading(value: 0, unit: .bytesPerSecond,
                                                           timestamp: timestamp, detail: networkDetail,
                                                           isPartial: true)
                advanced[.processGPUTime] = MetricReading(value: 0, unit: .seconds,
                                                          timestamp: timestamp, detail: gpuDetail,
                                                          isPartial: true)
            case 411:
                advanced[.processNetwork] = MetricReading(unavailable: .bytesPerSecond,
                                                           timestamp: timestamp, reason: .notCollected)
                advanced[.processGPUTime] = MetricReading(unavailable: .seconds,
                                                          timestamp: timestamp, reason: .notCollected)
            case 620:
                advanced[.processNetwork] = MetricReading(value: 10, unit: .bytesPerSecond, timestamp: timestamp)
                advanced[.processGPUTime] = MetricReading(value: 2, unit: .seconds, timestamp: timestamp)
            default:
                break
            }
            return copyProcess(process, advancedMetrics: advanced)
        }
        controller.update(snapshot: copy(snapshot, timestamp: timestamp, processes: processes))

        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSTableView?)
        setProcessSort("process.column.network", ascending: true, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table),
                       ["Fixture Editor", "Fixture Indexer"])

        let editorRow = try! XCTUnwrap(processRow(named: "Fixture Editor", controller: controller, table: table))
        let networkText = try! XCTUnwrap(processCellText("process.column.network", row: editorRow,
                                                         controller: controller, table: table))
        let gpuText = try! XCTUnwrap(processCellText("process.column.gpu", row: editorRow,
                                                     controller: controller, table: table))
        XCTAssertTrue(networkText.contains("partial"), networkText)
        XCTAssertTrue(networkText.contains(networkDetail), networkText)
        XCTAssertTrue(networkText.contains("1 of 2 members unavailable"), networkText)
        XCTAssertTrue(gpuText.contains("partial"), gpuText)
        XCTAssertTrue(gpuText.contains(gpuDetail), gpuText)
        XCTAssertTrue(gpuText.contains("1 of 2 members unavailable"), gpuText)

        let editorCell = try! XCTUnwrap(controller.tableView(table, viewFor: table.tableColumns[0], row: editorRow))
        try! XCTUnwrap(view(withIdentifier: "process.group.toggle.fixture-editor", in: editorCell) as NSButton?)
            .performClick(nil)
        let editorProcessRow = try! XCTUnwrap(processRow(named: "Fixture Editor Renderer", controller: controller,
                                                         table: table))
        let processNetworkText = try! XCTUnwrap(processCellText("process.column.network", row: editorProcessRow,
                                                                controller: controller, table: table))
        XCTAssertTrue(processNetworkText.contains("partial"), processNetworkText)
        XCTAssertTrue(processNetworkText.contains(networkDetail), processNetworkText)

        setProcessSort("process.column.network", ascending: false, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table),
                       ["Fixture Indexer", "Fixture Editor"])
    }

    func testUserAggregatePropagatesPartialInputWhenAllContributorsHaveValues() {
        let (_, store, _) = makeDependencies()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        let timestamp = snapshot.timestamp
        let detail = "one process CPU sample is a lower bound"
        let processes = snapshot.processes.map { process -> ProcessSnapshot in
            let cpu: MetricReading
            switch process.id.pid {
            case 410:
                cpu = MetricReading(value: 0, unit: .percent, timestamp: timestamp,
                                    detail: detail, isPartial: true)
            case 411:
                cpu = MetricReading(value: 10, unit: .percent, timestamp: timestamp)
            default:
                cpu = MetricReading(value: 5, unit: .percent, timestamp: timestamp)
            }
            return copyProcess(process, cpuPercent: cpu)
        }
        let updated = copy(snapshot, timestamp: timestamp, processes: processes)

        let controller = UsersViewController()
        controller.loadViewIfNeeded()
        controller.update(snapshot: updated)
        let table = try! XCTUnwrap(view(withIdentifier: "users.table", in: controller.view) as NSTableView?)
        let cpuText = try! XCTUnwrap(userCellText("cpu", row: 0, table: table))
        let expected = UIFormat.metric(MetricReading(value: 15, unit: .percent, timestamp: timestamp,
                                                     detail: detail, isPartial: true))
        XCTAssertEqual(cpuText, expected)
        XCTAssertTrue(cpuText.contains("partial"), cpuText)
        XCTAssertTrue(cpuText.contains(detail), cpuText)
    }

    func testDiskSortingKeepsUnavailablePairsLastForGroupsAndChildrenInBothDirections() {
        let (_, store, _) = makeDependencies()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        let timestamp = snapshot.timestamp
        func measured(_ value: Double, partial: Bool = false) -> MetricReading {
            MetricReading(value: value, unit: .bytesPerSecond, timestamp: timestamp,
                          detail: partial ? "lower bound" : nil, isPartial: partial)
        }
        let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                        reason: .collectionFailed)
        let specs: [(pid: Int32, name: String, read: MetricReading, write: MetricReading)] = [
            (100, "Missing", unavailable, unavailable),
            (101, "Zero", measured(0), measured(0)),
            (102, "Partial", measured(2, partial: true), measured(3)),
            (103, "Positive A", measured(10), measured(5)),
            (104, "Positive B", measured(10), measured(5)),
            (106, "Incomplete", unavailable, measured(100))
        ]
        let processes = specs.map { spec in
            makeDiskProcess(pid: spec.pid, name: "Child \(spec.name)", read: spec.read,
                            write: spec.write, timestamp: timestamp)
        }
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id.pid, $0) })
        var groups = specs.map { spec in
            let identity = byPID[spec.pid]!.id
            return makeDiskGroup(id: identity, title: "Disk \(spec.name)", members: [identity],
                                 read: spec.read, write: spec.write, timestamp: timestamp)
        }
        let allMembers = processes.map(\.id)
        groups.append(makeDiskGroup(id: ProcessIdentity(pid: 200,
                                                        startTime: ProcessStartTime(secondsSinceEpoch: 200, microseconds: 0)),
                                    title: "Disk Child Set", members: allMembers,
                                    read: measured(500), write: measured(500), timestamp: timestamp))

        let controller = ProcessesViewController(dependencies: makeDependencies().0)
        controller.loadViewIfNeeded()
        controller.update(snapshot: copy(snapshot, timestamp: timestamp,
                                         processes: processes, processGroups: groups))
        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSTableView?)

        setProcessSort("process.column.disk", ascending: true, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table), [
            "Disk Zero", "Disk Partial", "Disk Positive A", "Disk Positive B", "Disk Child Set",
            "Disk Missing", "Disk Incomplete"
        ])
        expandProcessGroup("Disk Child Set", controller: controller, table: table)
        XCTAssertEqual(childProcessNames(controller: controller, table: table), [
            "Child Zero", "Child Partial", "Child Positive A", "Child Positive B", "Child Missing", "Child Incomplete"
        ])

        setProcessSort("process.column.disk", ascending: false, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table), [
            "Disk Child Set", "Disk Positive A", "Disk Positive B", "Disk Partial", "Disk Zero",
            "Disk Missing", "Disk Incomplete"
        ])
        XCTAssertEqual(childProcessNames(controller: controller, table: table), [
            "Child Positive A", "Child Positive B", "Child Partial", "Child Zero", "Child Missing", "Child Incomplete"
        ])
    }

    func testSettingsRefreshesCachedControlsAndRoutesApprovalToFakeSettingsAction() async {
        let defaults = UserDefaults.standard
        let priorInterval = defaults.object(forKey: "monitoring.refreshInterval")
        let priorAppearance = AppearancePreference.current()
        defer {
            if let priorInterval { defaults.set(priorInterval, forKey: "monitoring.refreshInterval") }
            else { defaults.removeObject(forKey: "monitoring.refreshInterval") }
            AppearancePreference.apply(priorAppearance)
        }

        let (dependencies, store, integrations) = makeDependencies()
        let controller = SettingsViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()

        let intervalButton = try! XCTUnwrap(view(withIdentifier: "settings.refresh.2", in: controller.view) as NSButton?)
        intervalButton.performClick(nil)
        XCTAssertEqual(store.interval, .twoSeconds)
        XCTAssertTrue(textField(withIdentifier: "settings.sampling.state", in: controller.view)?.stringValue.contains("2.0 seconds") == true)

        store.setInterval(.fiveSeconds)
        store.pause()
        AppearancePreference.apply("dark")
        let refreshesBeforeAppearance = integrations.refreshCount
        controller.viewWillAppear()
        await waitUntil { integrations.refreshCount > refreshesBeforeAppearance }

        XCTAssertEqual(view(withIdentifier: "settings.refresh.5", in: controller.view).flatMap { ($0 as? NSButton)?.state }, .on)
        XCTAssertEqual(view(withIdentifier: "settings.refresh.2", in: controller.view).flatMap { ($0 as? NSButton)?.state }, .off)
        XCTAssertEqual(view(withIdentifier: "settings.appearance.dark", in: controller.view).flatMap { ($0 as? NSButton)?.state }, .on)
        XCTAssertEqual((view(withIdentifier: "settings.sampling.pause", in: controller.view) as? NSButton)?.title, "Resume Sampling")
        XCTAssertTrue(textField(withIdentifier: "settings.sampling.state", in: controller.view)?.stringValue.contains("Paused") == true)

        integrations.status = SystemIntegrationStatus(helper: .notConfigured, loginItem: .requiresApproval, updates: .current)
        let refreshesBeforeActivation = integrations.refreshCount
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        await waitUntil { integrations.refreshCount > refreshesBeforeActivation }

        let loginButton = try! XCTUnwrap(view(withIdentifier: "settings.login-item.toggle", in: controller.view) as NSButton?)
        XCTAssertEqual(loginButton.title, "Open at Login Settings")
        loginButton.performClick(nil)
        await waitUntil { integrations.openSettingsCount == 1 }
        XCTAssertEqual(integrations.launchItemChanges, [])
    }

    func testHistoryWindowUsesInclusiveUTCStartDayAtLocalNoonAndMidnight() {
        let (dependencies, store, _) = makeDependencies()
        let controller = HistoryViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let dailyTable = try! XCTUnwrap(allViews(in: controller.view).compactMap { $0 as? NSTableView }
            .first { $0.tableColumns.first?.identifier.rawValue == "day" })
        let base = try! XCTUnwrap(store.latestSnapshot)

        for timestamp in [date("2026-05-01T19:00:00Z"), date("2026-05-01T07:00:00Z")] {
            let history = [
                historyRow("2026-04-01", name: "Before cutoff"),
                historyRow("2026-04-02", name: "Oldest retained day"),
                historyRow("2026-05-01", name: "Current UTC day"),
                historyRow("2026-05-02", name: "Next UTC day")
            ]
            controller.update(snapshot: copy(base, timestamp: timestamp, applicationHistory: history))
            XCTAssertEqual(dailyTable.numberOfRows, 2)
        }
    }

    private func makeDependencies() -> (PageDependencies, FixtureMonitoringStore, FakeSystemIntegrationAPI) {
        let configuration = FixtureConfiguration(arguments: [])
        let store = FixtureMonitoringStore(configuration: configuration)
        let integrations = FakeSystemIntegrationAPI()
        return (PageDependencies(monitoringStore: store,
                                 processActions: FixtureProcessActioner(configuration: configuration),
                                 integrations: integrations,
                                 fixtureMode: true), store, integrations)
    }

    private func copyProcess(_ source: ProcessSnapshot, cpuPercent: MetricReading? = nil,
                             advancedMetrics: [MetricKind: MetricReading]? = nil) -> ProcessSnapshot {
        ProcessSnapshot(
            id: source.id, parentIdentity: source.parentIdentity, childIdentities: source.childIdentities,
            name: source.name, executablePath: source.executablePath, ownerUID: source.ownerUID,
            isCurrentUser: source.isCurrentUser, cpuPercent: cpuPercent ?? source.cpuPercent,
            memoryBytes: source.memoryBytes, diskReadBytesPerSecond: source.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: source.diskWriteBytesPerSecond,
            diskReadTotalBytes: source.diskReadTotalBytes, diskWriteTotalBytes: source.diskWriteTotalBytes,
            advancedMetrics: advancedMetrics ?? source.advancedMetrics,
            parentPID: source.parentPID, parentExecutablePath: source.parentExecutablePath)
    }

    private func makeDiskProcess(pid: Int32, name: String, read: MetricReading, write: MetricReading,
                                 timestamp: Date) -> ProcessSnapshot {
        let identity = ProcessIdentity(pid: pid,
                                       startTime: ProcessStartTime(secondsSinceEpoch: Int64(pid), microseconds: 0))
        let cpu = MetricReading(value: 0, unit: .percent, timestamp: timestamp)
        let bytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        return ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [], name: name,
            executablePath: nil, ownerUID: UInt32(getuid()), isCurrentUser: true,
            cpuPercent: cpu, memoryBytes: bytes, diskReadBytesPerSecond: read,
            diskWriteBytesPerSecond: write, diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes)
    }

    private func makeDiskGroup(id: ProcessIdentity, title: String, members: [ProcessIdentity],
                               read: MetricReading, write: MetricReading, timestamp: Date) -> ProcessGroupSnapshot {
        let zeroCPU = MetricReading(value: 0, unit: .percent, timestamp: timestamp)
        let zeroBytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        let zeroRate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        let historyIdentity = ApplicationHistoryIdentity(id: "disk-\(id.pid)", name: title,
                                                         executablePath: nil, association: .standalone)
        return ProcessGroupSnapshot(
            id: id, title: title, ownerUID: UInt32(getuid()), executablePath: nil,
            association: .standalone, historyIdentity: historyIdentity, members: members,
            cpuPercent: zeroCPU, memoryBytes: zeroBytes, diskReadBytesPerSecond: read,
            diskWriteBytesPerSecond: write, networkReceiveBytesPerSecond: zeroRate,
            networkTransmitBytesPerSecond: zeroRate)
    }

    private func setProcessSort(_ key: String, ascending: Bool,
                                controller: ProcessesViewController, table: NSTableView) {
        let oldDescriptors = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        controller.tableView(table, sortDescriptorsDidChange: oldDescriptors)
    }

    private func processRow(named name: String, controller: ProcessesViewController,
                            table: NSTableView) -> Int? {
        (0..<table.numberOfRows).first { row in
            processRowName(row, controller: controller, table: table) == name
        }
    }

    private func processRowName(_ row: Int, controller: ProcessesViewController, table: NSTableView) -> String? {
        guard let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: row) else { return nil }
        return textFields(in: cell).first?.stringValue
    }

    private func processGroupNames(controller: ProcessesViewController, table: NSTableView) -> [String] {
        (0..<table.numberOfRows).compactMap { row in
            guard table.rowView(atRow: row, makeIfNecessary: true)?.accessibilityIdentifier().hasPrefix("process.group.") == true else {
                return nil
            }
            return processRowName(row, controller: controller, table: table)
        }
    }

    private func childProcessNames(controller: ProcessesViewController, table: NSTableView) -> [String] {
        (0..<table.numberOfRows).compactMap { row in
            guard table.rowView(atRow: row, makeIfNecessary: true)?.accessibilityIdentifier().hasPrefix("process.row.") == true else {
                return nil
            }
            return processRowName(row, controller: controller, table: table)
        }
    }

    private func expandProcessGroup(_ title: String, controller: ProcessesViewController, table: NSTableView) {
        guard let row = processRow(named: title, controller: controller, table: table),
              let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: row),
              let toggle = view(withIdentifier: "process.group.toggle.\(slug(title))", in: cell) as? NSButton else {
            XCTFail("could not find the \(title) group disclosure")
            return
        }
        toggle.performClick(nil)
    }

    private func processCellText(_ key: String, row: Int,
                                 controller: ProcessesViewController, table: NSTableView) -> String? {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == key }),
              let cell = controller.tableView(table, viewFor: column, row: row) else { return nil }
        return textFields(in: cell).first?.stringValue
    }

    private func userCellText(_ key: String, row: Int, table: NSTableView) -> String? {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == key }),
              let cell = table.delegate?.tableView?(table, viewFor: column, row: row) else { return nil }
        return textFields(in: cell).first?.stringValue
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    private func copy(_ source: MonitoringSnapshot, timestamp: Date,
                      processes: [ProcessSnapshot]? = nil,
                      processGroups: [ProcessGroupSnapshot]? = nil,
                      applicationHistory: [ApplicationDailyHistorySummary]? = nil) -> MonitoringSnapshot {
        MonitoringSnapshot(timestamp: timestamp, system: source.system,
                           processes: processes ?? source.processes,
                           processGroups: processGroups ?? source.processGroups,
                           startupItems: source.startupItems, services: source.services,
                           users: source.users, discoveryCoverage: source.discoveryCoverage,
                           capabilities: source.capabilities, advancedMetrics: source.advancedMetrics,
                           history: source.history, applicationHistory: applicationHistory ?? source.applicationHistory)
    }

    private func historyRow(_ day: String, name: String) -> ApplicationDailyHistorySummary {
        let application = ApplicationHistoryIdentity(id: name, name: name, executablePath: nil, association: .standalone)
        return ApplicationDailyHistorySummary(dayStart: date("\(day)T00:00:00Z"), application: application,
                                              cpuSeconds: 1, diskReadBytes: nil, diskWriteBytes: nil,
                                              networkReceiveBytes: nil, networkTransmitBytes: nil,
                                              sampleCount: 1, gaps: 0, counterResets: 0)
    }

    private func selectedName(in controller: ProcessesViewController, table: NSTableView) -> String? {
        guard table.selectedRow >= 0,
              let cell = controller.tableView(table, viewFor: table.tableColumns[0], row: table.selectedRow) else { return nil }
        return textFields(in: cell).first(where: { $0.stringValue.hasPrefix("Fixture") })?.stringValue
    }

    private func textField(withIdentifier identifier: String, in root: NSView) -> NSTextField? {
        view(withIdentifier: identifier, in: root) as? NSTextField
    }

    private func view<T: NSView>(withIdentifier identifier: String, in root: NSView) -> T? {
        allViews(in: root).first { $0.accessibilityIdentifier() == identifier } as? T
    }

    private func textFields(in root: NSView?) -> [NSTextField] {
        guard let root else { return [] }
        return allViews(in: root).compactMap { $0 as? NSTextField }
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class FakeSystemIntegrationAPI: SystemIntegrationAPI {
    var status = SystemIntegrationStatus(helper: .notConfigured, loginItem: .disabled, updates: .idle)
    var onStatusChange: (@MainActor () -> Void)?
    private(set) var refreshCount = 0
    private(set) var openSettingsCount = 0
    private(set) var launchItemChanges: [Bool] = []

    func refreshStatus() async {
        refreshCount += 1
        onStatusChange?()
    }

    func removeHelper() async -> IntegrationActionResult { .completed }
    func configureHelper() async -> IntegrationActionResult { .completed }
    func setLaunchAtLogin(_ enabled: Bool) async -> IntegrationActionResult {
        launchItemChanges.append(enabled)
        return .completed
    }
    func openLoginItemSettings() async -> IntegrationActionResult {
        openSettingsCount += 1
        return .completed
    }
    func checkForUpdates() async -> IntegrationActionResult { .completed }
    func installAvailableUpdate() async -> IntegrationActionResult { .completed }
}
