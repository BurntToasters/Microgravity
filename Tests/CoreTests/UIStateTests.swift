import AppKit
import XCTest
@testable import Microgravity

@MainActor
private final class SnapshotTimestampRecorder {
    var values: [Date] = []
}

@MainActor
final class UIStateTests: XCTestCase {
    func testFixtureRefreshPulseRepeatsAndStopsAcrossPauseResume() async throws {
        let store = FixtureMonitoringStore(
            configuration: FixtureConfiguration(arguments: ["--ui-test-refresh-pulse"]),
            refreshPulseInitialDelayNanoseconds: 20_000_000,
            refreshPulseIntervalNanoseconds: 20_000_000
        )
        let recorder = SnapshotTimestampRecorder()
        store.onSnapshot = { recorder.values.append($0.timestamp) }

        store.start(interval: .oneSecond)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertGreaterThanOrEqual(recorder.values.count, 3, "Fixture pulse should publish repeatedly after initial snapshot.")

        store.pause()
        let pausedCount = recorder.values.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.values.count, pausedCount, "Paused fixture must not publish delayed snapshots.")

        store.resume()
        let resumedCount = recorder.values.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(recorder.values.count, resumedCount, "Resume should schedule new fixture snapshots.")

        store.stop()
        let stoppedCount = recorder.values.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.values.count, stoppedCount, "Stopped fixture must cancel its repeating task.")
    }

    func testProcessRootChildKeepsItsRowKindAcrossRefreshAndSortThenClearsOnCollapse() {
        let (dependencies, store, _) = makeDependencies()
        let controller = ProcessesViewController(dependencies: dependencies, defaults: isolatedProcessDefaults())
        controller.loadViewIfNeeded()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        controller.update(snapshot: snapshot)

        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSOutlineView?)
        expandProcessGroup("Fixture Editor", controller: controller, table: table)

        let rootRow = try! XCTUnwrap(processRow(named: "Fixture Editor Renderer", controller: controller, table: table))
        table.selectRowIndexes(IndexSet(integer: rootRow), byExtendingSelection: false)
        XCTAssertTrue(textField(withIdentifier: "process.selection.identity", in: controller.view)?.stringValue.contains("pid=410") == true)

        for offset in 1...4 {
            controller.update(snapshot: copy(snapshot, timestamp: snapshot.timestamp.addingTimeInterval(Double(offset))))
            XCTAssertNotNil(processRow(named: "Fixture Renderer Worker", controller: controller, table: table))
            XCTAssertEqual(selectedProcessName(controller: controller, table: table), "Fixture Editor Renderer")
        }

        setProcessSort("process.column.pid", ascending: false, controller: controller, table: table)
        XCTAssertEqual(selectedProcessName(controller: controller, table: table), "Fixture Editor Renderer")

        toggleProcessGroup("Fixture Editor", controller: controller, table: table)
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertEqual(textField(withIdentifier: "process.selection.identity", in: controller.view)?.stringValue, "No process selected")
    }

    func testProcessGroupExpansionRestoresAcrossControllerAndDropsReusedPID() throws {
        let suite = "ProcessExpansionUIState-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (dependencies, store, _) = makeDependencies()
        let snapshot = try XCTUnwrap(store.latestSnapshot)

        let first = ProcessesViewController(dependencies: dependencies, defaults: defaults)
        first.loadViewIfNeeded()
        first.update(snapshot: snapshot)
        let firstTable = try XCTUnwrap(view(withIdentifier: "process.table", in: first.view) as? NSOutlineView)
        expandProcessGroup("Fixture Editor", controller: first, table: firstTable)
        XCTAssertNotNil(processRow(named: "Fixture Renderer Worker", controller: first, table: firstTable))

        let relaunched = ProcessesViewController(dependencies: dependencies, defaults: defaults)
        relaunched.loadViewIfNeeded()
        relaunched.update(snapshot: snapshot)
        let relaunchedTable = try XCTUnwrap(view(withIdentifier: "process.table", in: relaunched.view) as? NSOutlineView)
        XCTAssertNotNil(processRow(named: "Fixture Renderer Worker", controller: relaunched, table: relaunchedTable))

        let originalLeader = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 410 })
        let replacementIdentity = ProcessIdentity(pid: originalLeader.id.pid,
                                                  startTime: ProcessStartTime(
                                                    secondsSinceEpoch: originalLeader.id.startTime.secondsSinceEpoch + 100,
                                                    microseconds: originalLeader.id.startTime.microseconds
                                                  ))
        let originalGroup = try XCTUnwrap(snapshot.processGroups.first { $0.id.pid == 410 })
        let replacementGroup = ProcessGroupSnapshot(
            id: replacementIdentity, title: originalGroup.title, ownerUID: originalGroup.ownerUID,
            executablePath: originalGroup.executablePath, association: originalGroup.association,
            historyIdentity: originalGroup.historyIdentity,
            members: originalGroup.members.map { $0 == originalLeader.id ? replacementIdentity : $0 },
            cpuPercent: originalGroup.cpuPercent, memoryBytes: originalGroup.memoryBytes,
            diskReadBytesPerSecond: originalGroup.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: originalGroup.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: originalGroup.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: originalGroup.networkTransmitBytesPerSecond
        )
        let reusedSnapshot = copy(
            snapshot, timestamp: snapshot.timestamp.addingTimeInterval(1),
            processes: snapshot.processes.map {
                $0.id == originalLeader.id ? copyProcess($0, identity: replacementIdentity) : $0
            },
            processGroups: snapshot.processGroups.map { $0.id == originalGroup.id ? replacementGroup : $0 }
        )
        let afterPIDReuse = ProcessesViewController(dependencies: dependencies, defaults: defaults)
        afterPIDReuse.loadViewIfNeeded()
        afterPIDReuse.update(snapshot: reusedSnapshot)
        let reusedTable = try XCTUnwrap(view(withIdentifier: "process.table", in: afterPIDReuse.view) as? NSOutlineView)
        XCTAssertNil(processRow(named: "Fixture Renderer Worker", controller: afterPIDReuse, table: reusedTable))
    }

    func testShowProcessInDetailsSelectsOnlyExactLiveIdentity() throws {
        let (_, store, _) = makeDependencies()
        let base = try XCTUnwrap(store.latestSnapshot)
        let original = try XCTUnwrap(base.processes.first { $0.id.pid == 410 })
        let replacementIdentity = ProcessIdentity(pid: original.id.pid,
                                                  startTime: ProcessStartTime(
                                                    secondsSinceEpoch: original.id.startTime.secondsSinceEpoch + 100,
                                                    microseconds: original.id.startTime.microseconds
                                                  ))
        let replacement = copyProcess(original, identity: replacementIdentity)
        let snapshot = copy(base, timestamp: base.timestamp,
                            processes: base.processes.map { $0.id == original.id ? replacement : $0 })
        let details = DetailsViewController(autosaveName: nil)
        details.loadViewIfNeeded()
        details.update(snapshot: snapshot)
        let table = try XCTUnwrap(view(withIdentifier: "details.table", in: details.view) as? NSTableView)

        details.selectProcess(identity: original.id)
        XCTAssertEqual(table.selectedRow, -1, "a reused PID must not satisfy a stale process identity")

        details.selectProcess(identity: replacementIdentity)
        XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
        XCTAssertEqual(table.rowView(atRow: table.selectedRow, makeIfNecessary: true)?.accessibilityIdentifier(),
                       "details.process.410")
    }

    func testProcessPIDReuseClearsSelectionByFullIdentity() {
        let (dependencies, store, _) = makeDependencies()
        let controller = ProcessesViewController(dependencies: dependencies, defaults: isolatedProcessDefaults())
        controller.loadViewIfNeeded()
        let snapshot = try! XCTUnwrap(store.latestSnapshot)
        controller.update(snapshot: snapshot)
        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSOutlineView?)
        expandProcessGroup("Fixture Editor", controller: controller, table: table)

        let rendererRow = try! XCTUnwrap(processRow(named: "Fixture Renderer Worker", controller: controller, table: table))
        table.selectRowIndexes(IndexSet(integer: rendererRow), byExtendingSelection: false)
        let oldRenderer = try! XCTUnwrap(snapshot.processes.first { $0.id.pid == 411 })
        let replacementID = ProcessIdentity(pid: oldRenderer.id.pid,
                                            startTime: ProcessStartTime(secondsSinceEpoch: oldRenderer.id.startTime.secondsSinceEpoch + 100,
                                                                        microseconds: oldRenderer.id.startTime.microseconds))
        let replacement = copyProcess(oldRenderer, identity: replacementID)
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
        let controller = ProcessesViewController(dependencies: dependencies, defaults: isolatedProcessDefaults())
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

        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSOutlineView?)
        setProcessSort("process.column.network", ascending: true, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table),
                       ["Fixture Editor", "Fixture Indexer"])

        // Partial values keep the number in the cell and move the explanation to the tooltip and a badge.
        let editorRow = try! XCTUnwrap(processRow(named: "Fixture Editor", controller: controller, table: table))
        let networkCell = try! XCTUnwrap(processCell("process.column.network", row: editorRow, controller: controller, table: table))
        let gpuCell = try! XCTUnwrap(processCell("process.column.gpu", row: editorRow, controller: controller, table: table))
        let networkValue = try! XCTUnwrap(textFields(in: networkCell).first)
        XCTAssertFalse(networkValue.stringValue.contains("partial"), networkValue.stringValue)
        XCTAssertTrue(isBadgeVisible(in: networkCell))
        let networkTip = networkValue.toolTip ?? ""
        XCTAssertTrue(networkTip.contains("Partial value"), networkTip)
        XCTAssertTrue(networkTip.contains(networkDetail), networkTip)
        XCTAssertTrue(networkTip.contains("1 of 2 members unavailable"), networkTip)
        let gpuTip = textFields(in: gpuCell).first?.toolTip ?? ""
        XCTAssertTrue(gpuTip.contains("Partial value"), gpuTip)
        XCTAssertTrue(gpuTip.contains(gpuDetail), gpuTip)
        XCTAssertTrue(gpuTip.contains("1 of 2 members unavailable"), gpuTip)

        expandProcessGroup("Fixture Editor", controller: controller, table: table)
        let editorProcessRow = try! XCTUnwrap(processRow(named: "Fixture Editor Renderer", controller: controller,
                                                         table: table))
        let processNetworkCell = try! XCTUnwrap(processCell("process.column.network", row: editorProcessRow,
                                                            controller: controller, table: table))
        let processNetworkTip = textFields(in: processNetworkCell).first?.toolTip ?? ""
        XCTAssertTrue(processNetworkTip.contains("Partial value"), processNetworkTip)
        XCTAssertTrue(processNetworkTip.contains(networkDetail), processNetworkTip)

        setProcessSort("process.column.network", ascending: false, controller: controller, table: table)
        XCTAssertEqual(processGroupNames(controller: controller, table: table),
                       ["Fixture Indexer", "Fixture Editor"])
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

        let controller = ProcessesViewController(dependencies: makeDependencies().0, defaults: isolatedProcessDefaults())
        controller.loadViewIfNeeded()
        controller.update(snapshot: copy(snapshot, timestamp: timestamp,
                                         processes: processes, processGroups: groups))
        let table = try! XCTUnwrap(view(withIdentifier: "process.table", in: controller.view) as NSOutlineView?)

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

        let intervalPopUp = try! XCTUnwrap(popUpButton(containing: "settings.refresh.2", in: controller.view))
        choose(item: "settings.refresh.2", in: intervalPopUp)
        XCTAssertEqual(store.interval, .twoSeconds)
        XCTAssertTrue(textField(withIdentifier: "settings.sampling.state", in: controller.view)?.stringValue.contains("2.0 seconds") == true)

        store.setInterval(.fiveSeconds)
        store.pause()
        AppearancePreference.apply("dark")
        let refreshesBeforeAppearance = integrations.refreshCount
        controller.viewWillAppear()
        await waitUntil { integrations.refreshCount > refreshesBeforeAppearance }

        XCTAssertEqual(popUpButton(containing: "settings.refresh.5", in: controller.view)?.selectedItem?.identifier?.rawValue,
                       "settings.refresh.5")
        XCTAssertEqual(popUpButton(containing: "settings.appearance.dark", in: controller.view)?.selectedItem?.identifier?.rawValue,
                       "settings.appearance.dark")
        XCTAssertEqual((view(withIdentifier: "settings.sampling.pause", in: controller.view) as? NSButton)?.title, "Resume Sampling")
        XCTAssertTrue(textField(withIdentifier: "settings.sampling.state", in: controller.view)?.stringValue.contains("Paused") == true)

        integrations.status = SystemIntegrationStatus(helper: .notConfigured, loginItem: .requiresApproval, updates: .current)
        let refreshesBeforeActivation = integrations.refreshCount
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        await waitUntil { integrations.refreshCount > refreshesBeforeActivation }

        let loginSwitch = try! XCTUnwrap(view(withIdentifier: "settings.login-item.toggle", in: controller.view) as NSSwitch?)
        XCTAssertEqual(loginSwitch.state, .off)
        let loginButton = try! XCTUnwrap(view(withIdentifier: "settings.login-item.open-settings", in: controller.view) as NSButton?)
        XCTAssertEqual(loginButton.attributedTitle.string, "Open Login Items Settings…")
        loginButton.performClick(nil)
        await waitUntil { integrations.openSettingsCount == 1 }
        XCTAssertEqual(integrations.launchItemChanges, [])
    }

    func testHistoryWindowUsesInclusiveUTCStartDayAtLocalNoonAndMidnight() {
        let (dependencies, store, _) = makeDependencies()
        let controller = HistoryViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let outline = try! XCTUnwrap(allViews(in: controller.view).compactMap { $0 as? NSOutlineView }.first)
        let base = try! XCTUnwrap(store.latestSnapshot)

        for timestamp in [date("2026-05-01T19:00:00Z"), date("2026-05-01T07:00:00Z")] {
            let history = [
                historyRow("2026-04-01", name: "Before cutoff"),
                historyRow("2026-04-02", name: "Oldest retained day"),
                historyRow("2026-05-01", name: "Current UTC day"),
                historyRow("2026-05-02", name: "Next UTC day")
            ]
            controller.update(snapshot: copy(base, timestamp: timestamp, applicationHistory: history))
            // Day rows are the children of the application rows (level 1 in the outline).
            let dayRows = (0..<outline.numberOfRows).filter { outline.level(forRow: $0) == 1 }
            XCTAssertEqual(dayRows.count, 2)
        }
    }

    func testFixtureModeSkipsAutosaveForDetailsAndInventoryTables() throws {
        let root = RootViewController(dependencies: makeFixtureAppDependencies())
        root.loadViewIfNeeded()
        for (page, identifier) in [(DashboardPage.details, "details.table"),
                                   (.startup, "startup.table"),
                                   (.services, "services.table")] {
            root.select(page)
            let table = try XCTUnwrap(view(withIdentifier: identifier, in: root.view) as? NSTableView,
                                      "\(identifier) should be on screen after selecting \(page)")
            XCTAssertNil(table.autosaveName, "\(identifier) must not autosave in fixture mode")
            XCTAssertFalse(table.autosaveTableColumns, "\(identifier) must not restore columns in fixture mode")
        }
    }

    func testInventoryAutosaveNamesKeepProductionNamesOutsideFixtureMode() {
        XCTAssertEqual(InventoryViewController.tableAutosaveName(for: .startup, fixtureMode: false), "startup.table")
        XCTAssertEqual(InventoryViewController.tableAutosaveName(for: .services, fixtureMode: false), "services.table")
        XCTAssertNil(InventoryViewController.tableAutosaveName(for: .startup, fixtureMode: true))
        XCTAssertNil(InventoryViewController.tableAutosaveName(for: .services, fixtureMode: true))
    }

    private func makeFixtureAppDependencies() -> AppDependencies {
        let configuration = FixtureConfiguration(arguments: [])
        return AppDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: true
        )
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

    private func isolatedProcessDefaults() -> UserDefaults {
        let suite = "UIStateProcessDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func copyProcess(_ source: ProcessSnapshot, identity: ProcessIdentity? = nil,
                             cpuPercent: MetricReading? = nil,
                             advancedMetrics: [MetricKind: MetricReading]? = nil) -> ProcessSnapshot {
        ProcessSnapshot(
            id: identity ?? source.id, parentIdentity: source.parentIdentity, childIdentities: source.childIdentities,
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

    private func processRow(named name: String, controller: ProcessesViewController,
                            table: NSOutlineView) -> Int? {
        (0..<table.numberOfRows).first { row in
            processRowName(row, controller: controller, table: table) == name
        }
    }

    private func processRowName(_ row: Int, controller: ProcessesViewController, table: NSOutlineView) -> String? {
        guard let cell = processCell("process.column.name", row: row, controller: controller, table: table) else { return nil }
        return textFields(in: cell).first?.stringValue
    }

    private func selectedProcessName(controller: ProcessesViewController, table: NSOutlineView) -> String? {
        guard table.selectedRow >= 0 else { return nil }
        return processRowName(table.selectedRow, controller: controller, table: table)
    }

    private func processGroupNames(controller: ProcessesViewController, table: NSOutlineView) -> [String] {
        (0..<table.numberOfRows).compactMap { row in
            guard table.rowView(atRow: row, makeIfNecessary: true)?.accessibilityIdentifier().hasPrefix("process.group.") == true else {
                return nil
            }
            return processRowName(row, controller: controller, table: table)
        }
    }

    private func childProcessNames(controller: ProcessesViewController, table: NSOutlineView) -> [String] {
        (0..<table.numberOfRows).compactMap { row in
            guard table.rowView(atRow: row, makeIfNecessary: true)?.accessibilityIdentifier().hasPrefix("process.row.") == true else {
                return nil
            }
            return processRowName(row, controller: controller, table: table)
        }
    }

    /// Clicks the group's disclosure target, which lives in the row view's leading gutter.
    private func toggleProcessGroup(_ title: String, controller: ProcessesViewController, table: NSOutlineView) {
        guard let row = processRow(named: title, controller: controller, table: table),
              let rowView = table.rowView(atRow: row, makeIfNecessary: true),
              let toggle = view(withIdentifier: "process.group.toggle.\(slug(title))", in: rowView) as NSButton? else {
            XCTFail("could not find the \(title) group disclosure")
            return
        }
        toggle.performClick(nil)
    }

    private func expandProcessGroup(_ title: String, controller: ProcessesViewController, table: NSOutlineView) {
        toggleProcessGroup(title, controller: controller, table: table)
    }

    private func setProcessSort(_ key: String, ascending: Bool,
                                controller: ProcessesViewController, table: NSOutlineView) {
        let oldDescriptors = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        controller.outlineView(table, sortDescriptorsDidChange: oldDescriptors)
    }

    /// The cell view the outline view would show for `row` in the named column.
    private func processCell(_ key: String, row: Int, controller: ProcessesViewController,
                             table: NSOutlineView) -> NSView? {
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == key }),
              let item = table.item(atRow: row) else { return nil }
        return controller.outlineView(table, viewFor: column, item: item)
    }

    private func isBadgeVisible(in root: NSView) -> Bool {
        allViews(in: root).compactMap { $0 as? NSImageView }.contains { !$0.isHidden && $0.image != nil }
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

    /// The pop-up whose menu contains an item with `itemIdentifier` (menu items are not in the view hierarchy).
    private func popUpButton(containing itemIdentifier: String, in root: NSView) -> NSPopUpButton? {
        allViews(in: root).compactMap { $0 as? NSPopUpButton }.first { popUp in
            popUp.itemArray.contains { $0.identifier?.rawValue == itemIdentifier }
        }
    }

    /// Selects the item and sends the pop-up's action, as a user choice would.
    private func choose(item itemIdentifier: String, in popUp: NSPopUpButton) {
        guard let index = popUp.itemArray.firstIndex(where: { $0.identifier?.rawValue == itemIdentifier }) else {
            XCTFail("missing pop-up item \(itemIdentifier)")
            return
        }
        popUp.selectItem(at: index)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
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
