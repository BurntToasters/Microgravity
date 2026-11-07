import XCTest
@testable import Microgravity

/// Pure row model for the Processes outline: diffing, selection identity, expansion, search, sort, heat and cell content.
@MainActor
final class ProcessRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Diff

    func testOperationsReproduceTheTargetForRandomReordersInsertsAndRemovals() {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<300 {
            let pool = Array(0..<20)
            let old = Array(pool.shuffled(using: &generator).prefix(Int.random(in: 0...20, using: &generator)))
            let new = Array(pool.shuffled(using: &generator).prefix(Int.random(in: 0...20, using: &generator)))
            let operations = ProcessRowModel.operations(from: old, to: new)
            XCTAssertEqual(ProcessRowModel.apply(operations, to: old), new, "old=\(old) new=\(new)")
            XCTAssertLessThanOrEqual(operations.count, old.count + new.count * 2)
        }
    }

    func testIdenticalListsProduceNoOperations() {
        XCTAssertEqual(ProcessRowModel.operations(from: [1, 2, 3], to: [1, 2, 3]), [])
    }

    func testInsertRemoveAndMoveKeepRowIdentities() {
        let operations = ProcessRowModel.operations(from: ["a", "b", "c", "d"], to: ["c", "a", "e", "d"])
        XCTAssertEqual(ProcessRowModel.apply(operations, to: ["a", "b", "c", "d"]), ["c", "a", "e", "d"])
        XCTAssertTrue(operations.contains(.remove(index: 1)), "\(operations)")
        XCTAssertTrue(operations.contains(.insert("e", index: 2)), "\(operations)")
        XCTAssertTrue(operations.contains { if case .move = $0 { return true } else { return false } }, "\(operations)")
    }

    // MARK: Selection and expansion

    func testSelectionFollowsIdentityAndIsDroppedWhenThePIDIsReused() {
        let original = ProcessRowID.process(identity(410, offset: 1))
        let reused = ProcessRowID.process(identity(410, offset: 2))
        XCTAssertEqual(ProcessRowModel.selection(after: original, visible: [.group(identity(100)), original]), original)
        XCTAssertNil(ProcessRowModel.selection(after: original, visible: [reused]))
        XCTAssertNil(ProcessRowModel.selection(after: nil, visible: [original]))
    }

    func testSelectionRowKindDistinguishesGroupLeaderFromItsChild() {
        let leader = identity(100)
        let visible: [ProcessRowID] = [.group(leader), .process(leader)]
        XCTAssertEqual(ProcessRowModel.selection(after: .process(leader), visible: visible), .process(leader))
        XCTAssertNil(ProcessRowModel.selection(after: .group(leader), visible: [.process(leader)]))
    }

    func testExpandedGroupKeepsItsChildrenAcrossRefreshWithChangedValues() {
        let fixture = sampleFixture()
        let before = ProcessRowModel.build(input(fixture.processes, fixture.groups, expanded: [identity(100)]))
        XCTAssertEqual(before.children[.group(identity(100))], [.process(identity(100)), .process(identity(101))])

        let hotter = fixture.processes.map { process -> ProcessSnapshot in
            process.id.pid == 101 ? copy(process, cpu: reading(55)) : process
        }
        let after = ProcessRowModel.build(input(hotter, fixture.groups, expanded: [identity(100)]))
        XCTAssertEqual(after.topLevel, before.topLevel)
        // The busier child now sorts first; the membership is unchanged.
        XCTAssertEqual(after.children[.group(identity(100))], [.process(identity(101)), .process(identity(100))])
        XCTAssertEqual(Set(after.children[.group(identity(100))] ?? []), Set(before.children[.group(identity(100))] ?? []))
        XCTAssertEqual(presentationText(for: after.rows[.process(identity(101))]?.cells[.cpu]), UIFormat.value(reading(55)))
    }

    func testCollapsedGroupsListNoChildRows() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups))
        XCTAssertTrue(output.children.isEmpty)
        XCTAssertNil(output.rows[.process(identity(101))])
        XCTAssertEqual(output.topLevel.count, 3)
    }

    func testCollapsedDuringSearchStaysCollapsedWhileTheSearchLasts() {
        let fixture = sampleFixture()
        let expanded = ProcessRowModel.build(input(fixture.processes, fixture.groups, query: "renderer"))
        XCTAssertEqual(expanded.children[.group(identity(100))], [.process(identity(101))])

        let collapsed = ProcessRowModel.build(input(fixture.processes, fixture.groups, query: "renderer",
                                                    collapsed: [identity(100)]))
        XCTAssertNil(collapsed.children[.group(identity(100))])
        XCTAssertEqual(collapsed.topLevel, [.group(identity(100))])
    }

    // MARK: Search

    func testSearchMatchesNameExecutablePathPIDAndUserCaseInsensitively() {
        let fixture = sampleFixture()
        XCTAssertEqual(topLevelTitles("RENDERER", fixture), ["Notes"])
        XCTAssertEqual(topLevelTitles("/applications/indexer", fixture), ["Indexer"])
        XCTAssertEqual(topLevelTitles("620", fixture), ["Indexer"])
        XCTAssertEqual(topLevelTitles("dev", fixture), ["Notes", "Indexer"])
        XCTAssertEqual(topLevelTitles("root", fixture), ["cron"])
        XCTAssertEqual(topLevelTitles("no-such-thing", fixture), [])
    }

    func testSearchShowsOnlyMatchingChildrenUnderAGroupThatMatchesOnlyThroughThem() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups, query: "renderer"))
        XCTAssertEqual(output.children[.group(identity(100))], [.process(identity(101))])
    }

    func testSearchShowsEveryChildWhenTheGroupItselfMatches() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups, query: "notes"))
        XCTAssertEqual(output.children[.group(identity(100))], [.process(identity(100)), .process(identity(101))])
    }

    // MARK: Sort

    func testUnavailableValuesSortLastInBothDirections() {
        let processes = [
            process(10, name: "Low", cpu: reading(5)),
            process(11, name: "Missing", cpu: unavailable(.percent)),
            process(12, name: "High", cpu: reading(10))
        ]
        let groups = processes.map { standaloneGroup($0) }
        let ascending = ProcessRowModel.build(input(processes, groups, sort: ProcessSortState(column: .cpu, ascending: true)))
        XCTAssertEqual(ascending.topLevel.map(\.identity.pid), [10, 12, 11])
        let descending = ProcessRowModel.build(input(processes, groups, sort: ProcessSortState(column: .cpu, ascending: false)))
        XCTAssertEqual(descending.topLevel.map(\.identity.pid), [12, 10, 11])
    }

    func testUserColumnSortsUnknownOwnersLast() {
        let processes = [
            process(10, name: "Owned", uid: 501, cpu: reading(1)),
            process(11, name: "Unknown", uid: nil, cpu: reading(1)),
            process(12, name: "Other", uid: 502, cpu: reading(1))
        ]
        let groups = processes.map { standaloneGroup($0) }
        let output = ProcessRowModel.build(input(processes, groups, sort: ProcessSortState(column: .user, ascending: false)))
        XCTAssertEqual(output.topLevel.map(\.identity.pid).last, 11)
    }

    // MARK: Heat and cell content

    func testHeatIsNilAtZeroAndFullAtTheColumnMaximum() {
        let processes = [
            process(10, name: "Busy", cpu: reading(100), disk: (reading(150), reading(50))),
            process(11, name: "Half", cpu: reading(50), disk: (reading(50), reading(50))),
            process(12, name: "Idle", cpu: reading(0), disk: (reading(0), reading(0)))
        ]
        let groups = processes.map { standaloneGroup($0) }
        let output = ProcessRowModel.build(input(processes, groups, physicalMemory: 8_000_000_000))

        XCTAssertEqual(metric(output.rows[.group(identity(10))], .cpu)?.1, 1.0)
        XCTAssertEqual(metric(output.rows[.group(identity(11))], .cpu)?.1, 0.5)
        XCTAssertEqual(metric(output.rows[.group(identity(12))], .cpu)?.1, 0.0)
        XCTAssertEqual(metric(output.rows[.group(identity(10))], .disk)?.1, 1.0)
        XCTAssertEqual(metric(output.rows[.group(identity(11))], .disk)?.1, 0.5)
        XCTAssertEqual(metric(output.rows[.group(identity(12))], .disk)?.1, 0.0)
        XCTAssertNil(metric(output.rows[.group(identity(10))], .gpu)?.1)
    }

    func testUnavailableMetricShowsDashAndReasonAndPartialShowsBadgeWithoutValueSuffix() {
        let partialNetwork = reading(1_000, .bytesPerSecond, partial: true, detail: "one interface omitted")
        let processes = [
            process(10, name: "Partial", cpu: unavailable(.percent), advanced: [.processNetwork: partialNetwork])
        ]
        let output = ProcessRowModel.build(input(processes, processes.map { standaloneGroup($0) }))
        let row = output.rows[.group(identity(10))]

        let network = metric(row, .network)?.0
        XCTAssertEqual(network?.badge, .partial)
        XCTAssertFalse(network?.valueText.contains("partial") ?? true)
        XCTAssertTrue(network?.toolTip?.contains("one interface omitted") ?? false)

        let cpu = metric(row, .cpu)?.0
        XCTAssertEqual(cpu?.valueText, "—")
        XCTAssertEqual(cpu?.badge, .unavailable)
        XCTAssertNotNil(cpu?.toolTip)
    }

    func testDiskCellCombinesReadAndWriteAndKeepsTheWorstBadge() {
        let read = MetricCellPresentation(reading(2_000, .bytesPerSecond))
        let write = MetricCellPresentation(reading(3_000, .bytesPerSecond, partial: true))
        let combined = ProcessRowModel.diskPresentation(read: read, write: write)
        XCTAssertEqual(combined.badge, .partial)
        XCTAssertTrue(combined.valueText.hasPrefix("R "))
        XCTAssertTrue(combined.valueText.contains(" · W "))
        XCTAssertFalse(combined.valueText.contains("partial"))
    }

    func testApplicationGroupUsesItsBundleIconAndOtherRowsUseNone() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups))
        if case .name(let notes)? = output.rows[.group(identity(100))]?.cells[.name] {
            XCTAssertEqual(notes.bundlePath, "/Applications/Notes.app")
            XCTAssertEqual(notes.accessibilityID, "process.group.notes")
            XCTAssertEqual(notes.isGroup, true)
        } else {
            XCTFail("missing name cell for the Notes group")
        }
        if case .name(let cron)? = output.rows[.group(identity(200))]?.cells[.name] {
            XCTAssertNil(cron.bundlePath)
        } else {
            XCTFail("missing name cell for cron")
        }
    }

    // MARK: Grouping and identifiers

    func testFlatGroupingListsEveryProcessWithoutGroups() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups, grouping: .flat))
        XCTAssertEqual(output.topLevel.count, fixture.processes.count)
        XCTAssertTrue(output.topLevel.allSatisfy { if case .process = $0 { return true } else { return false } })
        XCTAssertTrue(output.children.isEmpty)
    }

    func testAppBundlePathFindsTheBundleRoot() {
        XCTAssertEqual(ProcessRowModel.appBundlePath(for: "/Applications/Notes.app/Contents/MacOS/Notes"), "/Applications/Notes.app")
        XCTAssertEqual(ProcessRowModel.appBundlePath(for: "/Applications/Notes.app"), "/Applications/Notes.app")
        XCTAssertNil(ProcessRowModel.appBundlePath(for: "/usr/sbin/cron"))
        XCTAssertNil(ProcessRowModel.appBundlePath(for: nil))
    }

    func testDuplicateGroupTitlesGetDistinctRowAndToggleIdentifiers() {
        let first = identity(410, offset: 1)
        let second = identity(620, offset: 3)
        let groups = [
            group(first, title: "Fixture Editor", members: [first]),
            group(second, title: "Fixture Editor", members: [second])
        ]
        let processes = [process(410, name: "A", cpu: reading(1), identity: first),
                         process(620, name: "B", cpu: reading(1), identity: second)]
        let output = ProcessRowModel.build(input(processes, groups))
        let firstRow = output.rows[.group(first)]
        let secondRow = output.rows[.group(second)]
        XCTAssertNotEqual(firstRow?.accessibilityID, secondRow?.accessibilityID)
        XCTAssertNotEqual(firstRow?.toggleID, secondRow?.toggleID)
        XCTAssertTrue(firstRow?.toggleID?.hasPrefix("process.group.toggle.fixture-editor.pid-410-start-") == true)
    }

    func testSingleGroupTitleKeepsThePlainSlugIdentifier() {
        let fixture = sampleFixture()
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups))
        XCTAssertEqual(output.rows[.group(identity(100))]?.accessibilityID, "process.group.notes")
        XCTAssertEqual(output.rows[.group(identity(100))]?.toggleID, "process.group.toggle.notes")
    }

    // MARK: Fixtures

    private struct Fixture {
        let processes: [ProcessSnapshot]
        let groups: [ProcessGroupSnapshot]
    }

    /// Notes (app bundle, leader 100 with a child 101), cron (root, standalone) and Indexer (standalone, uid 501).
    private func sampleFixture() -> Fixture {
        let notes = process(100, name: "Notes", path: "/Applications/Notes.app/Contents/MacOS/Notes", cpu: reading(30))
        let renderer = process(101, name: "Renderer", path: "/System/Library/Helpers/renderer", cpu: reading(9),
                               parent: identity(100))
        let cron = process(200, name: "cron", path: "/usr/sbin/cron", uid: 0, cpu: reading(0.5))
        let indexer = process(620, name: "Indexer", path: "/Applications/Indexer.app/Contents/MacOS/Indexer", cpu: reading(3))
        let groups = [
            group(identity(100), title: "Notes", members: [identity(100), identity(101)],
                  path: "/Applications/Notes.app/Contents/MacOS/Notes", association: .applicationBundle),
            group(identity(200), title: "cron", members: [identity(200)], path: "/usr/sbin/cron", uid: 0),
            group(identity(620), title: "Indexer", members: [identity(620)],
                  path: "/Applications/Indexer.app/Contents/MacOS/Indexer")
        ]
        return Fixture(processes: [notes, renderer, cron, indexer], groups: groups)
    }

    private func identity(_ pid: Int32, offset: Int64 = 0) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: ProcessStartTime(secondsSinceEpoch: 1_700_000_000 + offset, microseconds: 0))
    }

    private func reading(_ value: Double, _ unit: MetricUnit = .percent, partial: Bool = false,
                         detail: String? = nil) -> MetricReading {
        MetricReading(value: value, unit: unit, timestamp: now, detail: detail, isPartial: partial)
    }

    private func unavailable(_ unit: MetricUnit) -> MetricReading {
        MetricReading(unavailable: unit, timestamp: now, reason: .notCollected)
    }

    private func process(_ pid: Int32, name: String, path: String? = nil, uid: UInt32? = 501,
                         cpu: MetricReading, disk: (MetricReading, MetricReading)? = nil,
                         advanced: [MetricKind: MetricReading] = [:], parent: ProcessIdentity? = nil,
                         identity: ProcessIdentity? = nil) -> ProcessSnapshot {
        let bytes = reading(100, .bytes)
        let read = disk?.0 ?? reading(0, .bytesPerSecond)
        let write = disk?.1 ?? reading(0, .bytesPerSecond)
        return ProcessSnapshot(
            id: identity ?? self.identity(pid), parentIdentity: parent, childIdentities: [], name: name,
            executablePath: path, ownerUID: uid, isCurrentUser: uid == 501,
            cpuPercent: cpu, memoryBytes: bytes, diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes, advancedMetrics: advanced)
    }

    private func copy(_ source: ProcessSnapshot, cpu: MetricReading) -> ProcessSnapshot {
        ProcessSnapshot(
            id: source.id, parentIdentity: source.parentIdentity, childIdentities: source.childIdentities,
            name: source.name, executablePath: source.executablePath, ownerUID: source.ownerUID,
            isCurrentUser: source.isCurrentUser, cpuPercent: cpu, memoryBytes: source.memoryBytes,
            diskReadBytesPerSecond: source.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: source.diskWriteBytesPerSecond,
            diskReadTotalBytes: source.diskReadTotalBytes, diskWriteTotalBytes: source.diskWriteTotalBytes,
            advancedMetrics: source.advancedMetrics)
    }

    private func group(_ leader: ProcessIdentity, title: String, members: [ProcessIdentity],
                       path: String? = nil, uid: UInt32? = 501,
                       association: ProcessGroupAssociation = .standalone) -> ProcessGroupSnapshot {
        let zero = reading(0)
        let zeroRate = reading(0, .bytesPerSecond)
        return ProcessGroupSnapshot(
            id: leader, title: title, ownerUID: uid, executablePath: path, association: association,
            historyIdentity: ApplicationHistoryIdentity(id: title.lowercased(), name: title,
                                                        executablePath: path, association: association),
            members: members, cpuPercent: zero, memoryBytes: reading(100, .bytes),
            diskReadBytesPerSecond: zeroRate, diskWriteBytesPerSecond: zeroRate,
            networkReceiveBytesPerSecond: zeroRate, networkTransmitBytesPerSecond: zeroRate)
    }

    /// A one-process group whose CPU and disk match the process, so sorts and heat read the same numbers.
    private func standaloneGroup(_ process: ProcessSnapshot) -> ProcessGroupSnapshot {
        let base = group(process.id, title: process.name, members: [process.id], path: process.executablePath,
                         uid: process.ownerUID)
        return ProcessGroupSnapshot(
            id: base.id, title: base.title, ownerUID: base.ownerUID, executablePath: base.executablePath,
            association: base.association, historyIdentity: base.historyIdentity, members: base.members,
            cpuPercent: process.cpuPercent, memoryBytes: process.memoryBytes,
            diskReadBytesPerSecond: process.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: process.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: base.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: base.networkTransmitBytesPerSecond)
    }

    private func input(_ processes: [ProcessSnapshot], _ groups: [ProcessGroupSnapshot],
                       query: String = "", grouping: ProcessGrouping = .byApp,
                       sort: ProcessSortState = ProcessSortState(column: .cpu, ascending: false),
                       expanded: Set<ProcessIdentity> = [], collapsed: Set<ProcessIdentity> = [],
                       physicalMemory: Double? = 8_000_000_000) -> ProcessOutlineInput {
        ProcessOutlineInput(
            processes: processes, groups: groups,
            capabilities: [.processNetwork: MetricAvailability(available: true),
                           .processGPUTime: MetricAvailability(available: false, reason: .unsupported)],
            timestamp: now, physicalMemoryBytes: physicalMemory, query: query, grouping: grouping, sort: sort,
            expandedGroups: expanded, collapsedDuringSearch: collapsed,
            ownerName: { uid in
                switch uid {
                case nil: return "Unavailable"
                case 501?: return "dev"
                case 0?: return "root"
                case let other?: return "uid \(other)"
                }
            })
    }

    private func topLevelTitles(_ query: String, _ fixture: Fixture) -> [String] {
        let output = ProcessRowModel.build(input(fixture.processes, fixture.groups, query: query))
        return output.topLevel.compactMap { output.rows[$0]?.title }
    }

    private func metric(_ row: ProcessRow?, _ column: ProcessColumn) -> (MetricCellPresentation, Double?)? {
        guard case .metric(let presentation, let heat)? = row?.cells[column] else { return nil }
        return (presentation, heat)
    }

    private func presentationText(for cell: ProcessCellContent?) -> String? {
        guard case .metric(let presentation, _)? = cell else { return nil }
        return presentation.valueText
    }
}

/// Deterministic generator so the randomized diff test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
