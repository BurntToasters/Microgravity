import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class ProcessInspectorTests: XCTestCase {
    func testRowsListEveryFieldInOrderAndReadParentFromTheSnapshot() throws {
        let snapshot = try XCTUnwrap(makeStore().latestSnapshot)
        let renderer = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 411 })
        let rows = ProcessInspectorModel.rows(process: renderer, group: nil, snapshot: snapshot,
                                              ownerName: { _ in "tester" })

        XCTAssertEqual(rows.map(\.label), [
            "Name", "PID", "Parent", "Owner", "Started", "Executable Path", "App Bundle", "CPU", "Memory",
            "Disk Read Rate", "Disk Write Rate", "Read Since Start", "Written Since Start", "Network"
        ])
        XCTAssertEqual(value("Name", rows), "Fixture Renderer Worker")
        XCTAssertEqual(value("PID", rows), "411")
        XCTAssertEqual(value("Parent", rows), "Fixture Editor Renderer (PID 410)")
        XCTAssertEqual(value("Owner", rows), "tester")
        XCTAssertEqual(value("Started", rows),
                       ProcessesViewController.startTimeFormatter.string(
                           from: ProcessesViewController.startDate(renderer.id.startTime)))
        XCTAssertEqual(value("Executable Path", rows), renderer.executablePath)
        XCTAssertEqual(value("App Bundle", rows), "/Applications/Fixture Editor.app")
        XCTAssertEqual(value("Read Since Start", rows), UIFormat.metric(renderer.diskReadTotalBytes))
        XCTAssertEqual(value("Written Since Start", rows), UIFormat.metric(renderer.diskWriteTotalBytes))
        XCTAssertEqual(value("Disk Read Rate", rows), UIFormat.metric(renderer.diskReadBytesPerSecond))
        XCTAssertEqual(rows.first { $0.label == "PID" }?.isMonospaced, true)
    }

    func testParentTextShowsNameListedPIDOrUnavailable() {
        let parent = makeProcess(pid: 999, parentIdentity: nil, parentPID: nil)
        let child = makeProcess(pid: 500, parentIdentity: parent.id, parentPID: nil)
        XCTAssertEqual(ProcessInspectorModel.parentText(child, byIdentity: [parent.id: parent]),
                       "Process 999 (PID 999)")
        XCTAssertEqual(ProcessInspectorModel.parentText(child, byIdentity: [:]), "PID 999")

        // A listed process with the parent's PID but a later start time is a reused PID, not the parent.
        let reused = makeProcess(pid: 999, startSeconds: 7_000, parentIdentity: nil, parentPID: nil)
        XCTAssertEqual(ProcessInspectorModel.parentText(child, byIdentity: [reused.id: reused]), "PID 999")

        let pidOnly = makeProcess(pid: 501, parentIdentity: nil, parentPID: 1)
        XCTAssertEqual(ProcessInspectorModel.parentText(pidOnly, byIdentity: [:]), "PID 1")

        let none = makeProcess(pid: 502, parentIdentity: nil, parentPID: nil)
        XCTAssertEqual(ProcessInspectorModel.parentText(none, byIdentity: [:]), "Unavailable")
    }

    func testUnavailableNetworkSaysWhyAndIsNeverZero() throws {
        let store = makeStore(arguments: ["--ui-test-network-unavailable"])
        let snapshot = try XCTUnwrap(store.latestSnapshot)
        let renderer = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 411 })
        let rows = ProcessInspectorModel.rows(process: renderer, group: nil, snapshot: snapshot,
                                              ownerName: { _ in "tester" })
        let network = try XCTUnwrap(value("Network", rows))
        XCTAssertTrue(network.hasPrefix("Unsupported"), network)
        XCTAssertFalse(network.hasPrefix("0"), network)
    }

    func testGroupRowShowsTheGroupsValuesAndSumsMemberTotals() throws {
        let snapshot = try XCTUnwrap(makeStore().latestSnapshot)
        let leader = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 410 })
        let renderer = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 411 })
        let group = try XCTUnwrap(snapshot.processGroups.first { $0.title == "Fixture Editor" })
        let rows = ProcessInspectorModel.rows(process: leader, group: group, snapshot: snapshot,
                                              ownerName: { _ in "tester" })

        XCTAssertEqual(value("Name", rows), "Fixture Editor")
        XCTAssertEqual(value("PID", rows), "410")
        XCTAssertEqual(value("CPU", rows), UIFormat.metric(group.cpuPercent))
        XCTAssertEqual(value("App Bundle", rows), "/Applications/Fixture Editor.app")
        let totalRead = try XCTUnwrap(leader.diskReadTotalBytes.value) + (renderer.diskReadTotalBytes.value ?? 0)
        XCTAssertEqual(value("Read Since Start", rows),
                       UIFormat.metric(MetricReading(value: totalRead, unit: .bytes, timestamp: snapshot.timestamp)))
    }

    func testStandaloneGroupHasNoAppBundle() throws {
        let snapshot = try XCTUnwrap(makeStore().latestSnapshot)
        let indexer = try XCTUnwrap(snapshot.processes.first { $0.id.pid == 620 })
        let group = try XCTUnwrap(snapshot.processGroups.first { $0.id.pid == 620 })
        XCTAssertEqual(group.association, .standalone)
        let rows = ProcessInspectorModel.rows(process: indexer, group: group, snapshot: snapshot,
                                              ownerName: { _ in "tester" })
        XCTAssertEqual(value("App Bundle", rows), "None")
    }

    func testInspectorKeepsItsIdentifiersAndUpdatesValuesInPlace() throws {
        let inspector = ProcessInspectorViewController()
        inspector.loadViewIfNeeded()
        XCTAssertEqual(inspector.view.accessibilityIdentifier(), "process.inspector")

        let icon = AppIconProvider.genericExecutableIcon()
        inspector.update(title: "Fixture Editor", icon: icon, executablePath: "/Applications/Fixture Editor.app",
                         rows: [
                            ProcessInspectorRow(label: "PID", value: "410", toolTip: nil, isMonospaced: true),
                            ProcessInspectorRow(label: "Executable Path", value: "/Applications/Fixture Editor.app",
                                                toolTip: "/Applications/Fixture Editor.app", isMonospaced: false)
                         ])
        let pid = try XCTUnwrap(view(withIdentifier: "process.inspector.pid", in: inspector.view) as NSTextField?)
        XCTAssertEqual(pid.stringValue, "410")
        let path = view(withIdentifier: "process.inspector.executable-path", in: inspector.view) as NSTextField?
        XCTAssertEqual(path?.stringValue, "/Applications/Fixture Editor.app")
        let copy = try XCTUnwrap(view(withIdentifier: "process.inspector.copy-path", in: inspector.view) as NSButton?)
        XCTAssertTrue(copy.isEnabled)

        inspector.update(title: "Fixture Editor", icon: icon, executablePath: nil, rows: [
            ProcessInspectorRow(label: "PID", value: "411", toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: "Executable Path", value: "Unavailable", toolTip: nil, isMonospaced: false)
        ])
        let samePID = view(withIdentifier: "process.inspector.pid", in: inspector.view) as NSTextField?
        XCTAssertTrue(samePID === pid,
                      "same labels keep their value fields")
        XCTAssertEqual(pid.stringValue, "411")
        XCTAssertFalse(copy.isEnabled, "Copy Path is disabled without a path")
        XCTAssertEqual(textField(withIdentifier: "process.inspector.footer", in: inspector.view)?.stringValue,
                       "Updates live while open")
    }

    // MARK: - Helpers

    private func makeStore(arguments: [String] = []) -> FixtureMonitoringStore {
        FixtureMonitoringStore(configuration: FixtureConfiguration(arguments: arguments))
    }

    private func value(_ label: String, _ rows: [ProcessInspectorRow]) -> String? {
        rows.first { $0.label == label }?.value
    }

    private func makeProcess(pid: Int32, startSeconds: Int64? = nil, parentIdentity: ProcessIdentity?,
                             parentPID: Int32?) -> ProcessSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let start = ProcessStartTime(secondsSinceEpoch: startSeconds ?? Int64(pid), microseconds: 0)
        let identity = ProcessIdentity(pid: pid, startTime: start)
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        let bytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        return ProcessSnapshot(
            id: identity, parentIdentity: parentIdentity, childIdentities: [], name: "Process \(pid)",
            executablePath: nil, ownerUID: UInt32(getuid()), isCurrentUser: true,
            cpuPercent: MetricReading(value: 0, unit: .percent, timestamp: timestamp),
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes, parentPID: parentPID
        )
    }

    private func textField(withIdentifier identifier: String, in root: NSView) -> NSTextField? {
        view(withIdentifier: identifier, in: root) as? NSTextField
    }

    private func view<T: NSView>(withIdentifier identifier: String, in root: NSView) -> T? {
        allViews(in: root).first { $0.accessibilityIdentifier() == identifier } as? T
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }
}
