import AppKit
import XCTest
@testable import Microgravity

/// Checks that the Processes outline and its row mirror (`mirroredRowIDs`) agree after each snapshot.
@MainActor
final class ProcessOutlineReconcileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // (a) By Category: an expanded group that NSWorkspace reclassifies moves from Background to Apps.
    func testExpandedGroupChangingCategoryKeepsOutlineAndMirrorInStep() {
        let agent = identity(200)
        let helper = identity(201)
        let notes = identity(100)
        let daemon = identity(400)
        let defaults = isolatedDefaults(grouping: "byCategory", expandedGroups: [agent])
        let (controller, outline) = makeController(defaults: defaults)

        let processes = [
            makeProcess(identity: notes, name: "Notes", path: "/Applications/Notes.app/Contents/MacOS/Notes",
                        uid: 501, cpu: 20, category: .application),
            makeProcess(identity: agent, name: "Agent", path: "/usr/local/bin/agent", uid: 501, cpu: 30),
            makeProcess(identity: helper, name: "Agent Helper", path: "/usr/local/bin/agent-helper", uid: 501, cpu: 3),
            makeProcess(identity: daemon, name: "Daemon", path: "/usr/local/bin/daemon", uid: 501, cpu: 5)
        ]
        func groups(agentCategory: ProcessCategory) -> [ProcessGroupSnapshot] {
            [
                makeGroup(notes, title: "Notes", members: [notes], uid: 501, cpu: 20, category: .application),
                makeGroup(agent, title: "Agent", members: [agent, helper], uid: 501, cpu: 33, category: agentCategory),
                makeGroup(daemon, title: "Daemon", members: [daemon], uid: 501, cpu: 5, category: .background)
            ]
        }

        controller.update(snapshot: snapshot(processes, groups(agentCategory: .background)))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertNotNil(rowItem(for: .process(helper), in: outline))

        if let row = row(for: .process(helper), in: outline) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        controller.update(snapshot: snapshot(processes, groups(agentCategory: .application)))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertTrue(controller.mirroredRowIDs.contains(.process(helper)))
        XCTAssertEqual(rowItem(for: .process(helper), in: outline).flatMap { outline.parent(forItem: $0) as? ProcessRowItem }?.id,
                       .group(agent))
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? ProcessRowItem)?.id, .process(helper))
    }

    // (b) By Category: more than 40 groups reorder inside a section that holds an expanded group.
    func testMoreThanFortyReorderedGroupsKeepExpandedMemberVisible() {
        let count = 45
        func leader(_ index: Int) -> ProcessIdentity { identity(Int32(1000 + index)) }
        let expandedMember = identity(2000)
        let defaults = isolatedDefaults(grouping: "byCategory", expandedGroups: [leader(0)])
        let (controller, outline) = makeController(defaults: defaults)

        func build(reversed: Bool) -> MonitoringSnapshot {
            var processes: [ProcessSnapshot] = []
            var groups: [ProcessGroupSnapshot] = []
            for index in 0..<count {
                let rank = Double(reversed ? count - index : index + 1)
                let id = leader(index)
                processes.append(makeProcess(identity: id, name: "App \(index)", path: "/Applications/App\(index).app/Contents/MacOS/App",
                                             uid: 501, cpu: rank, category: .application))
                let members = index == 0 ? [id, expandedMember] : [id]
                groups.append(makeGroup(id, title: "App \(index)", members: members, uid: 501, cpu: rank, category: .application))
            }
            processes.append(makeProcess(identity: expandedMember, name: "Expanded Helper",
                                         path: "/Applications/App0.app/Contents/Helpers/helper", uid: 501, cpu: 0.5,
                                         category: .application))
            return snapshot(processes, groups)
        }

        controller.update(snapshot: build(reversed: false))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertTrue(controller.mirroredRowIDs.contains(.process(expandedMember)))

        // Reversing 45 groups needs more than 40 row steps, so the section is reloaded instead.
        controller.update(snapshot: build(reversed: true))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertTrue(controller.mirroredRowIDs.contains(.process(expandedMember)))
        XCTAssertEqual(rowItem(for: .process(expandedMember), in: outline).flatMap { outline.parent(forItem: $0) as? ProcessRowItem }?.id,
                       .group(leader(0)))
    }

    // (c) By App: a process moves from one expanded group to another, and the destination is processed first.
    func testProcessMovingBetweenExpandedGroupsKeepsOutlineAndMirrorInStep() {
        let aLeader = identity(100)
        let aOther = identity(102)
        let bLeader = identity(200)
        let bOther = identity(201)
        let mover = identity(101)
        let defaults = isolatedDefaults(grouping: "byApp", expandedGroups: [aLeader, bLeader])
        let (controller, outline) = makeController(defaults: defaults)

        let processes = [
            makeProcess(identity: aLeader, name: "Alpha", path: "/Applications/Alpha.app/Contents/MacOS/Alpha", uid: 501, cpu: 10,
                        category: .application),
            makeProcess(identity: aOther, name: "Alpha Worker", path: "/Applications/Alpha.app/Contents/Helpers/worker", uid: 501,
                        cpu: 1, category: .application),
            makeProcess(identity: mover, name: "Mover", path: "/usr/local/bin/mover", uid: 501, cpu: 2),
            makeProcess(identity: bLeader, name: "Beta", path: "/Applications/Beta.app/Contents/MacOS/Beta", uid: 501, cpu: 10,
                        category: .application),
            makeProcess(identity: bOther, name: "Beta Worker", path: "/Applications/Beta.app/Contents/Helpers/worker", uid: 501,
                        cpu: 1, category: .application)
        ]
        func build(moverGroup: ProcessIdentity) -> MonitoringSnapshot {
            let alphaMembers = moverGroup == aLeader ? [aLeader, aOther, mover] : [aLeader, aOther]
            let betaMembers = moverGroup == bLeader ? [bLeader, bOther, mover] : [bLeader, bOther]
            return snapshot(processes, [
                makeGroup(bLeader, title: "Beta", members: betaMembers, uid: 501, cpu: 60, category: .application),
                makeGroup(aLeader, title: "Alpha", members: alphaMembers, uid: 501, cpu: 50, category: .application)
            ])
        }

        controller.update(snapshot: build(moverGroup: aLeader))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertEqual(rowItem(for: .process(mover), in: outline).flatMap { outline.parent(forItem: $0) as? ProcessRowItem }?.id,
                       .group(aLeader))

        controller.update(snapshot: build(moverGroup: bLeader))
        assertOutlineMatchesMirror(controller, outline)
        XCTAssertEqual(rowItem(for: .process(mover), in: outline).flatMap { outline.parent(forItem: $0) as? ProcessRowItem }?.id,
                       .group(bLeader))
    }

    // MARK: - Assertions

    private func assertOutlineMatchesMirror(_ controller: ProcessesViewController, _ outline: NSOutlineView,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let mirror = controller.mirroredRowIDs
        XCTAssertEqual(outline.numberOfRows, mirror.count, "outline row count must equal the mirror's visible count",
                       file: file, line: line)
        for row in 0..<min(outline.numberOfRows, mirror.count) {
            XCTAssertEqual((outline.item(atRow: row) as? ProcessRowItem)?.id, mirror[row],
                           "row \(row) must show the mirror's row", file: file, line: line)
        }
    }

    // MARK: - Hosting

    private func makeController(defaults: UserDefaults) -> (ProcessesViewController, NSOutlineView) {
        let configuration = FixtureConfiguration(arguments: [])
        let store = FixtureMonitoringStore(configuration: configuration)
        let controller = ProcessesViewController(dependencies: PageDependencies(
            monitoringStore: store,
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true), defaults: defaults)
        controller.loadViewIfNeeded()
        guard let outline = findOutline(in: controller.view) else {
            fatalError("Processes outline not found")
        }
        return (controller, outline)
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = findOutline(in: subview) { return outline }
        }
        return nil
    }

    private func isolatedDefaults(grouping: String, expandedGroups: [ProcessIdentity]) -> UserDefaults {
        let suite = "ProcessOutlineReconcile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(grouping, forKey: "process.grouping")
        ProcessGroupExpansionPersistence.save(Set(expandedGroups), to: defaults)
        return defaults
    }

    private func row(for id: ProcessRowID, in outline: NSOutlineView) -> Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? ProcessRowItem)?.id == id }
    }

    private func rowItem(for id: ProcessRowID, in outline: NSOutlineView) -> ProcessRowItem? {
        row(for: id, in: outline).flatMap { outline.item(atRow: $0) as? ProcessRowItem }
    }

    // MARK: - Fixtures

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: 1_700_000_000, microseconds: 0))
    }

    private func snapshot(_ processes: [ProcessSnapshot], _ groups: [ProcessGroupSnapshot]) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: now).system
        return MonitoringSnapshot(timestamp: now, system: base, processes: processes, processGroups: groups,
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:], capabilities: [:])
    }

    private func makeProcess(identity: ProcessIdentity, name: String, path: String? = nil, uid: UInt32? = 501,
                             cpu: Double = 1, category: ProcessCategory = .background) -> ProcessSnapshot {
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: now)
        let bytes = MetricReading(value: 1_024, unit: .bytes, timestamp: now)
        return ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [],
            name: name, executablePath: path, ownerUID: uid, isCurrentUser: uid == 501,
            cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: now),
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes,
            advancedMetrics: [.processNetwork: rate, .processNetworkReceive: rate, .processNetworkTransmit: rate],
            category: category
        )
    }

    private func makeGroup(_ id: ProcessIdentity, title: String, members: [ProcessIdentity],
                           uid: UInt32?, cpu: Double, category: ProcessCategory) -> ProcessGroupSnapshot {
        let zeroRate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: now)
        let association: ProcessGroupAssociation = category == .application ? .applicationBundle : .standalone
        return ProcessGroupSnapshot(
            id: id, title: title, ownerUID: uid, executablePath: nil,
            association: association,
            historyIdentity: ApplicationHistoryIdentity(id: title.lowercased(), name: title, executablePath: nil,
                                                        association: association),
            members: members, cpuPercent: MetricReading(value: cpu, unit: .percent, timestamp: now),
            memoryBytes: MetricReading(value: 1_024, unit: .bytes, timestamp: now),
            diskReadBytesPerSecond: zeroRate, diskWriteBytesPerSecond: zeroRate,
            networkReceiveBytesPerSecond: zeroRate, networkTransmitBytesPerSecond: zeroRate,
            category: category
        )
    }
}
