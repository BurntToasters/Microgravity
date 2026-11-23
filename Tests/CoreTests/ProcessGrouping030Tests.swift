import XCTest
@testable import Microgravity

@MainActor
final class ProcessGrouping030Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeduplicatesAppBundlesByPathAndOwnerAndPicksMainExecutableLeader() {
        let mainID = identity(510)
        let helperID = identity(501) // Lower PID than main, but inside Contents/Frameworks
        let rootMainID = identity(610)

        let helper = makeProcess(
            identity: helperID, parentIdentity: identity(1),
            name: "Editor Helper",
            path: "/Applications/FixtureEditor.app/Contents/Frameworks/Editor Helper.app/Contents/MacOS/Editor Helper",
            uid: 501, category: .background
        )
        let main = makeProcess(
            identity: mainID, parentIdentity: identity(1),
            name: "FixtureEditor",
            path: "/Applications/FixtureEditor.app/Contents/MacOS/FixtureEditor",
            uid: 501, category: .application
        )
        let rootCopy = makeProcess(
            identity: rootMainID, parentIdentity: identity(1),
            name: "FixtureEditor",
            path: "/Applications/FixtureEditor.app/Contents/MacOS/FixtureEditor",
            uid: 0, category: .system
        )

        let groups = SystemMonitorCollector.groupProcessesForTesting(
            [helper, main, rootCopy], timestamp: now, regularAppPIDs: [510]
        )
        let editorGroups = groups.filter { $0.title == "FixtureEditor" }
        XCTAssertEqual(editorGroups.count, 2, "distinct owners must stay separate while same-owner bundle instances merge")

        let userGroup = editorGroups.first { $0.ownerUID == 501 }
        XCTAssertEqual(userGroup?.id, mainID, "main Contents/MacOS binary must be chosen over lower-PID Framework helper")
        XCTAssertEqual(Set(userGroup?.members ?? []), [mainID, helperID])
        XCTAssertEqual(userGroup?.category, .application)

        let rootGroup = editorGroups.first { $0.ownerUID == 0 }
        XCTAssertEqual(rootGroup?.members, [rootMainID])
    }

    func testLaunchdDoesNotSwallowStandardUserDescendants() {
        let launchdID = identity(1)
        let agentID = identity(700)
        let workerID = identity(701)

        let launchd = makeProcess(identity: launchdID, parentIdentity: nil, name: "launchd", path: "/sbin/launchd", uid: 0, category: .system)
        var agent = makeProcess(identity: agentID, parentIdentity: launchdID, name: "UserAgent", path: "/usr/local/bin/agent", uid: 501, category: .background)
        agent = copyProcess(agent, childIdentities: [workerID])
        let worker = makeProcess(identity: workerID, parentIdentity: agentID, name: "AgentWorker", path: "/usr/local/bin/worker", uid: 501, category: .background)

        let groups = SystemMonitorCollector.groupProcessesForTesting([launchd, agent, worker], timestamp: now, regularAppPIDs: [])
        let launchdGroup = groups.first { $0.id == launchdID }
        XCTAssertEqual(launchdGroup?.members, [launchdID], "launchd must remain standalone rather than claiming UID 501 children")
        let agentGroup = groups.first { $0.id == agentID }
        XCTAssertEqual(Set(agentGroup?.members ?? []), [agentID, workerID])
    }

    func testProcessCategoryClassificationByCategorySectionsAndScopeFilters() {
        XCTAssertEqual(
            SystemMonitorCollector.classifyProcessCategory(pid: 10, ownerUID: 0, executablePath: "/usr/local/bin/tool", regularAppPIDs: []),
            .system
        )
        XCTAssertEqual(
            SystemMonitorCollector.classifyProcessCategory(pid: 11, ownerUID: 501, executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", regularAppPIDs: []),
            .system
        )
        XCTAssertEqual(
            SystemMonitorCollector.classifyProcessCategory(pid: 12, ownerUID: 501, executablePath: "/Applications/Notes.app/Contents/MacOS/Notes", regularAppPIDs: [12]),
            .application
        )
        XCTAssertEqual(
            SystemMonitorCollector.classifyProcessCategory(pid: 13, ownerUID: 501, executablePath: "/usr/local/bin/node", regularAppPIDs: [12]),
            .background
        )

        let appID = identity(100)
        let bgID = identity(200)
        let sysID = identity(300)
        let processes = [
            makeProcess(identity: appID, name: "Notes", path: "/Applications/Notes.app/Contents/MacOS/Notes", uid: 501, cpu: 20, category: .application),
            makeProcess(identity: bgID, name: "Agent", path: "/usr/local/bin/agent", uid: 501, cpu: 30, category: .background),
            makeProcess(identity: sysID, name: "daemon", path: "/usr/sbin/daemon", uid: 0, cpu: 10, category: .system)
        ]
        let groups = [
            makeGroup(appID, title: "Notes", members: [appID], uid: 501, cpu: 20, category: .application),
            makeGroup(bgID, title: "Agent", members: [bgID], uid: 501, cpu: 30, category: .background),
            makeGroup(sysID, title: "daemon", members: [sysID], uid: 0, cpu: 10, category: .system)
        ]

        let byCat = ProcessRowModel.build(makeInput(processes, groups, grouping: .byCategory))
        XCTAssertEqual(byCat.topLevel, [.section(.application), .section(.background), .section(.system)])
        XCTAssertEqual(byCat.rows[.section(.application)]?.title, "Apps")
        XCTAssertEqual(byCat.rows[.section(.background)]?.title, "Background processes")
        XCTAssertEqual(byCat.rows[.section(.system)]?.title, "System processes")
        XCTAssertEqual(byCat.children[.section(.application)], [.group(appID)])
        XCTAssertEqual(byCat.children[.section(.background)], [.group(bgID)])
        XCTAssertEqual(byCat.children[.section(.system)], [.group(sysID)])

        let appsOnly = ProcessRowModel.build(makeInput(processes, groups, grouping: .byApp, scopeFilter: .apps, currentUID: 501))
        XCTAssertEqual(appsOnly.topLevel, [.group(appID)])

        let myProcesses = ProcessRowModel.build(makeInput(processes, groups, grouping: .byApp, scopeFilter: .myProcesses, currentUID: 501))
        XCTAssertEqual(Set(myProcesses.topLevel), [.group(bgID), .group(appID)])
    }

    func testOneMemberGroupIsNonExpandableWhileMultiMemberGroupIsExpandable() {
        let soloID = identity(10)
        let parentID = identity(20)
        let childID = identity(21)
        let processes = [
            makeProcess(identity: soloID, name: "Solo", uid: 501, cpu: 5),
            makeProcess(identity: parentID, name: "Multi", uid: 501, cpu: 10),
            makeProcess(identity: childID, name: "Multi Helper", uid: 501, cpu: 2)
        ]
        let groups = [
            makeGroup(soloID, title: "Solo", members: [soloID], uid: 501, cpu: 5),
            makeGroup(parentID, title: "Multi", members: [parentID, childID], uid: 501, cpu: 12)
        ]
        let output = ProcessRowModel.build(makeInput(processes, groups))
        XCTAssertEqual(output.rows[.group(soloID)]?.isExpandable, false)
        XCTAssertNil(output.rows[.group(soloID)]?.toggleID)
        if case let .name(content)? = output.rows[.group(soloID)]?.cells[.name] {
            XCTAssertEqual(content.memberCount, 1)
        } else {
            XCTFail("expected name content for solo group")
        }

        XCTAssertEqual(output.rows[.group(parentID)]?.isExpandable, true)
        XCTAssertNotNil(output.rows[.group(parentID)]?.toggleID)
        if case let .name(content)? = output.rows[.group(parentID)]?.cells[.name] {
            XCTAssertEqual(content.memberCount, 2)
        } else {
            XCTFail("expected name content for multi-member group")
        }
    }

    func testRoutineLifecycleReasonsAndSmallJitterDoNotProducePartialOrHistoryGaps() async throws {
        let t0 = now
        let t1 = now.addingTimeInterval(1)
        let t1Jitter = now.addingTimeInterval(1.02)
        let intervalA = DateInterval(start: t0, end: t1)
        let intervalB = DateInterval(start: t0.addingTimeInterval(0.01), end: t1Jitter)

        let combined = SystemMonitorCollector.combineRates([
            MetricReading(value: 1_000, unit: .bytesPerSecond, timestamp: t1, measurementInterval: intervalA),
            MetricReading(value: 500, unit: .bytesPerSecond, timestamp: t1Jitter, measurementInterval: intervalB),
            MetricReading(unavailable: .bytesPerSecond, timestamp: t1, reason: .warmingUp),
            MetricReading(unavailable: .bytesPerSecond, timestamp: t1, reason: .processExited),
            MetricReading(unavailable: .bytesPerSecond, timestamp: t1, reason: .identityChanged)
        ], unit: .bytesPerSecond, timestamp: t1)

        XCTAssertEqual(combined.value, 1_500)
        XCTAssertFalse(combined.isPartial, "routine sibling unavailability and <=50ms interval jitter must not set isPartial")
        XCTAssertNotNil(combined.measurementInterval)

        // Verify SQLiteMonitoringHistoryStore also avoids creating false gaps when duplicate history rows combine.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mg-hist-030-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SQLiteMonitoringHistoryStore(databaseURL: tempDir.appendingPathComponent("history.sqlite"),
                                                 timeZone: TimeZone(secondsFromGMT: 0)!)

        let sharedHistory = ApplicationHistoryIdentity(id: "bundle:com.example.App", name: "Example", executablePath: "/Applications/Example.app", association: .applicationBundle)
        let groupA0 = makeHistoryGroup(identity(1), history: sharedHistory, cpu: 10, rx: 0, tx: 0, interval: nil, reason: nil, at: t0)
        let groupB0 = makeHistoryGroup(identity(2), history: sharedHistory, cpu: 0, rx: 0, tx: 0, interval: nil, reason: .warmingUp, at: t0)
        try await store.record(snapshot: makeHistorySnapshot(at: t0, groups: [groupA0, groupB0]))

        let groupA1 = makeHistoryGroup(identity(1), history: sharedHistory, cpu: 20, rx: 1_000, tx: 200, interval: intervalA, reason: nil, at: t1)
        let groupB1 = makeHistoryGroup(identity(2), history: sharedHistory, cpu: 10, rx: 500, tx: 100, interval: intervalB, reason: .warmingUp, at: t1Jitter)
        try await store.record(snapshot: makeHistorySnapshot(at: t1, groups: [groupA1, groupB1]))

        let summaryRows = try await store.applicationSummaries(lastDays: 30, through: t1)
        let summary = try XCTUnwrap(summaryRows.first)
        XCTAssertEqual(summary.gaps, 0, "routine warmingUp + 20ms jitter must not create a history gap")
    }

    func testFittedNameWidthAccountsForInsetPaddingAtMinimumAndDefaultWidths() {
        // Default 0.3.0 columns excluding GPU sum to 462 pt; .inset table adds 36 pt horizontal padding.
        XCTAssertEqual(ProcessesViewController.fittedNameWidth(visibleWidth: 960, otherColumnWidths: 462, minimum: 150, horizontalInset: 36), 462)
        XCTAssertEqual(ProcessesViewController.fittedNameWidth(visibleWidth: 1280, otherColumnWidths: 462, minimum: 150, horizontalInset: 36), 782)
        XCTAssertEqual(ProcessesViewController.fittedNameWidth(visibleWidth: 600, otherColumnWidths: 462, minimum: 150, horizontalInset: 36), 150)
    }

    // MARK: - Helpers

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: 1_700_000_000, microseconds: 0))
    }

    private func makeProcess(identity: ProcessIdentity, parentIdentity: ProcessIdentity? = nil,
                             name: String, path: String? = nil, uid: UInt32? = 501,
                             cpu: Double = 1, category: ProcessCategory = .background) -> ProcessSnapshot {
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: now)
        let bytes = MetricReading(value: 1_024, unit: .bytes, timestamp: now)
        return ProcessSnapshot(
            id: identity, parentIdentity: parentIdentity, childIdentities: [],
            name: name, executablePath: path, ownerUID: uid, isCurrentUser: uid == 501,
            cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: now),
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes,
            advancedMetrics: [.processNetwork: rate, .processNetworkReceive: rate, .processNetworkTransmit: rate],
            category: category
        )
    }

    private func copyProcess(_ source: ProcessSnapshot, childIdentities: [ProcessIdentity]) -> ProcessSnapshot {
        ProcessSnapshot(
            id: source.id, parentIdentity: source.parentIdentity, childIdentities: childIdentities,
            name: source.name, executablePath: source.executablePath, ownerUID: source.ownerUID,
            isCurrentUser: source.isCurrentUser, cpuPercent: source.cpuPercent, memoryBytes: source.memoryBytes,
            diskReadBytesPerSecond: source.diskReadBytesPerSecond, diskWriteBytesPerSecond: source.diskWriteBytesPerSecond,
            diskReadTotalBytes: source.diskReadTotalBytes, diskWriteTotalBytes: source.diskWriteTotalBytes,
            advancedMetrics: source.advancedMetrics, category: source.category
        )
    }

    private func makeGroup(_ id: ProcessIdentity, title: String, members: [ProcessIdentity],
                           uid: UInt32?, cpu: Double, category: ProcessCategory = .background) -> ProcessGroupSnapshot {
        let zeroRate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: now)
        return ProcessGroupSnapshot(
            id: id, title: title, ownerUID: uid, executablePath: nil,
            association: category == .application ? .applicationBundle : .standalone,
            historyIdentity: ApplicationHistoryIdentity(id: title.lowercased(), name: title, executablePath: nil,
                                                        association: category == .application ? .applicationBundle : .standalone),
            members: members, cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: now),
            memoryBytes: MetricReading(value: 1_024, unit: .bytes, timestamp: now),
            diskReadBytesPerSecond: zeroRate, diskWriteBytesPerSecond: zeroRate,
            networkReceiveBytesPerSecond: zeroRate, networkTransmitBytesPerSecond: zeroRate,
            category: category
        )
    }

    private func makeInput(_ processes: [ProcessSnapshot], _ groups: [ProcessGroupSnapshot],
                           grouping: ProcessGrouping = .byApp,
                           scopeFilter: ProcessScopeFilter = .all,
                           currentUID: UInt32 = 501) -> ProcessOutlineInput {
        ProcessOutlineInput(
            processes: processes, groups: groups,
            capabilities: [.processNetwork: MetricAvailability(available: true)],
            timestamp: now, physicalMemoryBytes: 8_000_000_000, query: "",
            grouping: grouping, sort: ProcessSortState(column: .cpu, ascending: false),
            expandedGroups: [], collapsedDuringSearch: [],
            ownerName: { $0 == 0 ? "root" : "dev" },
            scopeFilter: scopeFilter, currentUID: currentUID, collapsedCategories: []
        )
    }

    private func makeHistoryGroup(_ id: ProcessIdentity, history: ApplicationHistoryIdentity,
                                  cpu: Double, rx: Double, tx: Double,
                                  interval: DateInterval?, reason: MetricUnavailableReason?,
                                  at timestamp: Date) -> ProcessGroupSnapshot {
        let rxReading = reason.map { MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0) }
            ?? MetricReading(value: rx, unit: .bytesPerSecond, timestamp: timestamp, measurementInterval: interval)
        let txReading = reason.map { MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: $0) }
            ?? MetricReading(value: tx, unit: .bytesPerSecond, timestamp: timestamp, measurementInterval: interval)
        let disk = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        return ProcessGroupSnapshot(
            id: id, title: history.name, ownerUID: 501, executablePath: history.executablePath,
            association: history.association, historyIdentity: history, members: [id],
            cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: timestamp),
            memoryBytes: MetricReading(value: 1_024, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: disk, diskWriteBytesPerSecond: disk,
            networkReceiveBytesPerSecond: rxReading, networkTransmitBytesPerSecond: txReading,
            category: .application
        )
    }

    private func makeHistorySnapshot(at timestamp: Date, groups: [ProcessGroupSnapshot]) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp).system
        return MonitoringSnapshot(timestamp: timestamp, system: base, processes: [], processGroups: groups,
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:], capabilities: [:])
    }
}
