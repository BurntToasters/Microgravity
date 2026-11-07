import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class PerformanceViewControllerTests: XCTestCase {
    func testPartialMetricTextKeepsNumericValueUnitDetailAndMeasuredZero() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = "one sampler was unavailable"
        let complete = UIFormat.metric(MetricReading(value: 42.5, unit: .percent, timestamp: timestamp))
        let partial = UIFormat.metric(MetricReading(value: 42.5, unit: .percent, timestamp: timestamp,
                                                    detail: detail, isPartial: true))
        XCTAssertEqual(partial, "\(complete) · partial · \(detail)")

        let zero = UIFormat.metric(MetricReading(value: 0, unit: .percent, timestamp: timestamp))
        let partialZero = UIFormat.metric(MetricReading(value: 0, unit: .percent, timestamp: timestamp,
                                                        isPartial: true))
        XCTAssertNotEqual(zero, "Unavailable")
        XCTAssertEqual(partialZero, "\(zero) · partial")

        let unavailable = MetricReading(unavailable: .percent, timestamp: timestamp,
                                        reason: .collectionFailed, detail: "capture failed", isPartial: true)
        XCTAssertEqual(UIFormat.metric(unavailable), "Collection failed · capture failed")
    }

    func testDiskPresentationNamesCurrentValuesAndTracksHistoryScale() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let read = MetricReading(value: 1_024, unit: .bytesPerSecond, timestamp: timestamp)
        let write = MetricReading(value: 2_048, unit: .bytesPerSecond, timestamp: timestamp)
        let first = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: read,
            firstHistory: [read], secondName: "Write", second: write, secondHistory: [write])
        let largerHistoricalWrite = MetricReading(value: 32_768, unit: .bytesPerSecond, timestamp: timestamp)
        let afterHistoryGrowth = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: read,
            firstHistory: [read], secondName: "Write", second: write,
            secondHistory: [write, largerHistoricalWrite])

        XCTAssertEqual(first.firstValueText, "Read: \(UIFormat.metric(read))")
        XCTAssertEqual(first.secondValueText, "Write: \(UIFormat.metric(write))")
        XCTAssertEqual(first.firstAccessibilityLabel, "Current disk Read throughput")
        XCTAssertEqual(first.secondAccessibilityLabel, "Current disk Write throughput")
        XCTAssertEqual(first.graphMaximum, 2_048)
        XCTAssertEqual(afterHistoryGrowth.graphMaximum, 32_768,
                       "the scale must follow the largest reading retained in graph history")
        XCTAssertEqual(afterHistoryGrowth.scaleText,
                       "Scale maximum: \(UIFormat.bytesPerSecond(32_768))")
        XCTAssertEqual(afterHistoryGrowth.scaleAccessibilityLabel, "Disk throughput graph scale maximum")
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("Disk throughput graph"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("Current Read:"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("current Write:"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains(afterHistoryGrowth.scaleText))
    }

    func testNetworkPresentationNamesReceiveAndSendValues() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let receive = MetricReading(value: 4_096, unit: .bytesPerSecond, timestamp: timestamp)
        let send = MetricReading(value: 8_192, unit: .bytesPerSecond, timestamp: timestamp)
        let presentation = ThroughputGraphPresentation(
            graphName: "Network throughput", subjectName: "network", firstName: "Receive", first: receive,
            firstHistory: [receive], secondName: "Send", second: send, secondHistory: [send])

        XCTAssertEqual(presentation.firstValueText, "Receive: \(UIFormat.metric(receive))")
        XCTAssertEqual(presentation.secondValueText, "Send: \(UIFormat.metric(send))")
        XCTAssertEqual(presentation.firstAccessibilityLabel, "Current network Receive throughput")
        XCTAssertEqual(presentation.secondAccessibilityLabel, "Current network Send throughput")
        XCTAssertEqual(presentation.graphMaximum, 8_192)
        XCTAssertEqual(presentation.scaleAccessibilityLabel, "Network throughput graph scale maximum")
        XCTAssertTrue(presentation.accessibilitySummary.contains("Network throughput graph"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Current Receive:"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("current Send:"))
    }

    func testUnavailableThroughputHasClearValuesAndNoDataScale() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let permissionDenied = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                             reason: .permissionDenied)
        let unsupported = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                        reason: .unsupported)
        let presentation = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: permissionDenied,
            firstHistory: [permissionDenied], secondName: "Write", second: unsupported,
            secondHistory: [unsupported])

        XCTAssertEqual(presentation.firstValueText, "Read: Permission denied")
        XCTAssertEqual(presentation.secondValueText, "Write: Unsupported")
        XCTAssertEqual(presentation.graphMaximum, 1, "an empty graph retains its drawing fallback")
        XCTAssertEqual(presentation.scaleText, "Scale maximum: no data")
        XCTAssertTrue(presentation.accessibilitySummary.contains("No graph samples have available data"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Current Read: Permission denied"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("current Write: Unsupported"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Scale maximum: no data"))
    }

    func testControllerWiresThroughputValuesScaleAndAccessibilityAtNarrowWidth() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierTimestamp = timestamp.addingTimeInterval(-2)
        let laterHistoryTimestamp = timestamp.addingTimeInterval(-1)
        let current = throughputSnapshot(
            timestamp: timestamp,
            diskRead: reading(1_024, timestamp), diskWrite: reading(2_048, timestamp),
            networkReceive: reading(4_096, timestamp), networkSend: reading(8_192, timestamp))
        let earlier = throughputSnapshot(
            timestamp: earlierTimestamp,
            diskRead: reading(16_384, earlierTimestamp), diskWrite: reading(32_768, earlierTimestamp),
            networkReceive: reading(32_768, earlierTimestamp), networkSend: reading(65_536, earlierTimestamp))
        let latestHistory = throughputSnapshot(
            timestamp: laterHistoryTimestamp,
            diskRead: reading(64_000, laterHistoryTimestamp), diskWrite: reading(48_000, laterHistoryTimestamp),
            networkReceive: reading(128_000, laterHistoryTimestamp), networkSend: reading(96_000, laterHistoryTimestamp))
        let store = MutablePerformanceMonitoringStore()
        let dependencies = PageDependencies(monitoringStore: store,
                                            processActions: UnusedProcessActioner(),
                                            integrations: UnavailableSystemIntegrationAPI(),
                                            fixtureMode: false)
        let controller = PerformanceViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        controller.view.setFrameSize(NSSize(width: 500, height: 700))

        store.replace(snapshot: current, samples: [earlier, latestHistory, current].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: current)
        controller.view.layoutSubtreeIfNeeded()

        let diskRead = try XCTUnwrap(view(withIdentifier: "performance.disk.read.value", in: controller.view) as? NSTextField)
        let diskWrite = try XCTUnwrap(view(withIdentifier: "performance.disk.write.value", in: controller.view) as? NSTextField)
        let diskScale = try XCTUnwrap(view(withIdentifier: "performance.graph.disk.scale", in: controller.view) as? NSTextField)
        let diskGraph = try XCTUnwrap(view(withIdentifier: "performance.graph.disk", in: controller.view))
        let networkReceive = try XCTUnwrap(view(withIdentifier: "performance.network.receive.value", in: controller.view) as? NSTextField)
        let networkSend = try XCTUnwrap(view(withIdentifier: "performance.network.send.value", in: controller.view) as? NSTextField)
        let networkScale = try XCTUnwrap(view(withIdentifier: "performance.graph.network.scale", in: controller.view) as? NSTextField)
        let networkGraph = try XCTUnwrap(view(withIdentifier: "performance.graph.network", in: controller.view))

        XCTAssertEqual(diskRead.stringValue, "Read: \(UIFormat.metric(current.system.diskReadBytesPerSecond))")
        XCTAssertEqual(diskWrite.stringValue, "Write: \(UIFormat.metric(current.system.diskWriteBytesPerSecond))")
        XCTAssertEqual(diskRead.accessibilityLabel(), "Current disk Read throughput")
        XCTAssertEqual(diskWrite.accessibilityLabel(), "Current disk Write throughput")
        XCTAssertEqual(diskScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(64_000))")
        XCTAssertEqual(diskScale.accessibilityLabel(), "Disk throughput graph scale maximum")
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Disk throughput graph") == true)
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Current Read:") == true)
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Scale maximum: \(UIFormat.bytesPerSecond(64_000))") == true)

        XCTAssertEqual(networkReceive.stringValue, "Receive: \(UIFormat.metric(current.system.networkReceiveBytesPerSecond))")
        XCTAssertEqual(networkSend.stringValue, "Send: \(UIFormat.metric(current.system.networkTransmitBytesPerSecond))")
        XCTAssertEqual(networkReceive.accessibilityLabel(), "Current network Receive throughput")
        XCTAssertEqual(networkSend.accessibilityLabel(), "Current network Send throughput")
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(128_000))")
        XCTAssertEqual(networkScale.accessibilityLabel(), "Network throughput graph scale maximum")
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("Current Receive:") == true)
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("Scale maximum: \(UIFormat.bytesPerSecond(128_000))") == true)

        let expandedTimestamp = timestamp.addingTimeInterval(1)
        let expandedCurrent = throughputSnapshot(
            timestamp: expandedTimestamp,
            diskRead: reading(256_000, expandedTimestamp), diskWrite: reading(192_000, expandedTimestamp),
            networkReceive: reading(512_000, expandedTimestamp), networkSend: reading(384_000, expandedTimestamp))
        store.replace(snapshot: expandedCurrent,
                      samples: [earlier, latestHistory, current, expandedCurrent].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: expandedCurrent)
        XCTAssertEqual(diskScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(256_000))",
                       "the controller must refresh the scale as graph history changes")
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(512_000))")

        let detail = String(repeating: "Permission detail that should truncate safely. ", count: 12)
        let unavailableTimestamp = expandedTimestamp.addingTimeInterval(1)
        let unavailable = throughputSnapshot(
            timestamp: unavailableTimestamp,
            diskRead: unavailableReading(unavailableTimestamp, detail), diskWrite: unavailableReading(unavailableTimestamp, detail),
            networkReceive: unavailableReading(unavailableTimestamp, detail), networkSend: unavailableReading(unavailableTimestamp, detail))
        store.replace(snapshot: unavailable,
                      samples: [earlier, latestHistory, current, expandedCurrent].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: unavailable)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(diskRead.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertTrue(diskWrite.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertTrue(networkReceive.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertTrue(networkSend.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertEqual(diskScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(256_000))",
                       "unavailable current data must not erase the historical graph scale")
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(512_000))")
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Current Read: Permission denied · \(detail)") == true)
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("current Send: Permission denied · \(detail)") == true)

        for field in [diskRead, diskWrite, networkReceive, networkSend] {
            XCTAssertEqual(field.lineBreakMode, .byTruncatingTail)
            XCTAssertTrue(field.usesSingleLineMode)
            let valueRow = try XCTUnwrap(field.superview)
            let card = try XCTUnwrap(valueRow.superview?.superview?.superview)
            let valueRowInCard = valueRow.convert(valueRow.bounds, to: card)
            XCTAssertGreaterThanOrEqual(valueRowInCard.minX, -1)
            XCTAssertLessThanOrEqual(valueRowInCard.maxX, card.bounds.maxX - 12,
                                     "long unavailable details must stay within the card width")
        }
    }

    private func reading(_ value: Double, _ timestamp: Date) -> MetricReading {
        MetricReading(value: value, unit: .bytesPerSecond, timestamp: timestamp)
    }

    private func unavailableReading(_ timestamp: Date, _ detail: String) -> MetricReading {
        MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                      reason: .permissionDenied, detail: detail)
    }

    private func throughputSnapshot(timestamp: Date, diskRead: MetricReading, diskWrite: MetricReading,
                                    networkReceive: MetricReading, networkSend: MetricReading) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let original = base.system
        let system = SystemMetricsSnapshot(
            capacityCores: original.capacityCores, cpuPercent: original.cpuPercent,
            perCoreCPUPercent: original.perCoreCPUPercent,
            memoryUsedBytes: original.memoryUsedBytes, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: original.memoryTotalBytes, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: diskRead, diskWriteBytesPerSecond: diskWrite,
            networkReceiveBytesPerSecond: networkReceive, networkTransmitBytesPerSecond: networkSend,
            networkInterfaces: original.networkInterfaces)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: base.processes,
                                  processGroups: base.processGroups, startupItems: base.startupItems,
                                  services: base.services, users: base.users,
                                  discoveryCoverage: base.discoveryCoverage, capabilities: base.capabilities,
                                  advancedMetrics: base.advancedMetrics, history: base.history,
                                  applicationHistory: base.applicationHistory)
    }

    private func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
        ([root] + root.subviews.flatMap(allViews(in:))).first { $0.accessibilityIdentifier() == identifier }
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }
}

@MainActor
private final class MutablePerformanceMonitoringStore: MonitoringStore {
    private(set) var latestSnapshot: MonitoringSnapshot?
    private(set) var graphSamples: [MonitoringGraphSample] = []
    private(set) var interval: MonitoringInterval = .oneSecond
    private(set) var isPaused = false
    private(set) var isRunning = false
    var onSnapshot: (@MainActor @Sendable (MonitoringSnapshot) -> Void)?

    func replace(snapshot: MonitoringSnapshot, samples: [MonitoringGraphSample]) {
        latestSnapshot = snapshot
        graphSamples = samples
    }

    func start(interval: MonitoringInterval) { self.interval = interval; isRunning = true; isPaused = false }
    func setInterval(_ interval: MonitoringInterval) { self.interval = interval }
    func pause() { isPaused = true }
    func resume() { isPaused = false; isRunning = true }
    func stop() { isPaused = false; isRunning = false }
    func refreshNow() async {}
    func resetHistory() async throws {}
}

private struct UnusedProcessActioner: ProcessActioning {
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        ProcessActionResult(identity: identity, force: force,
                            outcome: .rejected(.helperUnavailable, detail: nil))
    }
}
