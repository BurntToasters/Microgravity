import AppKit
import XCTest
@testable import Microgravity

/// The Processes summary strip must render every reading shape without trapping and show "—" for missing values.
@MainActor
final class ProcessSummaryStripViewTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    func testNormalValuesRenderAsBefore() throws {
        let strip = ProcessSummaryStripView(frame: NSRect(x: 0, y: 0, width: 640, height: 46))
        let snapshot = CoreTestFixtures.snapshot(timestamp: timestamp, cpuPercent: 42.5,
                                                 diskReadRate: 1_500, diskWriteRate: 500,
                                                 networkReceiveRate: 2_000, networkTransmitRate: 0)
        strip.update(snapshot: snapshot)

        XCTAssertEqual(try valueText(.cpu, in: strip), UIFormat.percent(42.5))
        XCTAssertEqual(try valueText(.disk, in: strip), UIFormat.bytesPerSecond(2_000))
        XCTAssertEqual(try valueText(.network, in: strip), UIFormat.bytesPerSecond(2_000))
    }

    func testNormalMemoryShowsWholePercentAndBytes() throws {
        let used = MetricReading(value: 4_294_967_296, unit: .bytes, timestamp: timestamp)
        let total = MetricReading(value: 17_179_869_184, unit: .bytes, timestamp: timestamp)
        let strip = ProcessSummaryStripView(frame: .zero)
        strip.update(snapshot: snapshot(memoryUsed: used, memoryTotal: total))

        XCTAssertEqual(try valueText(.memory, in: strip), "25% · \(UIFormat.bytes(4_294_967_296))")
    }

    func testNilSnapshotShowsMissingPresentationForEveryTile() throws {
        let strip = ProcessSummaryStripView(frame: .zero)
        strip.update(snapshot: nil)

        for metric in [PerformanceMetric.cpu, .memory, .disk, .network] {
            XCTAssertEqual(try valueText(metric, in: strip), "—")
        }
    }

    func testNonFiniteRatesShowMissingPresentationWithoutTrapping() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            let strip = ProcessSummaryStripView(frame: .zero)
            let snapshot = CoreTestFixtures.snapshot(timestamp: timestamp, cpuPercent: bad,
                                                     diskReadRate: bad, diskWriteRate: 0,
                                                     networkReceiveRate: 0, networkTransmitRate: bad)
            strip.update(snapshot: snapshot)
            XCTAssertEqual(try valueText(.cpu, in: strip), "—")
            XCTAssertEqual(try valueText(.disk, in: strip), "—")
            XCTAssertEqual(try valueText(.network, in: strip), "—")
        }
    }

    func testNonFiniteMemoryReadingsShowNoPercentAndMissingWhenUsedIsMissing() throws {
        let finiteTotal = MetricReading(value: 17_179_869_184, unit: .bytes, timestamp: timestamp)
        let missingUsed = MetricReading(unavailable: .bytes, timestamp: timestamp, reason: .warmingUp)
        let cases: [(used: MetricReading, total: MetricReading)] = [
            (MetricReading(value: .nan, unit: .bytes, timestamp: timestamp), finiteTotal),
            (MetricReading(value: .infinity, unit: .bytes, timestamp: timestamp), finiteTotal),
            (missingUsed, finiteTotal),
            (MetricReading(value: 4_294_967_296, unit: .bytes, timestamp: timestamp),
             MetricReading(value: .nan, unit: .bytes, timestamp: timestamp)),
            (MetricReading(value: 4_294_967_296, unit: .bytes, timestamp: timestamp),
             MetricReading(value: .infinity, unit: .bytes, timestamp: timestamp)),
            (MetricReading(value: 1e308, unit: .bytes, timestamp: timestamp),
             MetricReading(value: 1e-300, unit: .bytes, timestamp: timestamp))
        ]
        for (used, total) in cases {
            let strip = ProcessSummaryStripView(frame: .zero)
            strip.update(snapshot: snapshot(memoryUsed: used, memoryTotal: total))
            let text = try valueText(.memory, in: strip)
            XCTAssertFalse(text.contains("%"), "no percent without finite readings: \(text)")
        }

        let missing = ProcessSummaryStripView(frame: .zero)
        missing.update(snapshot: snapshot(memoryUsed: missingUsed, memoryTotal: finiteTotal))
        XCTAssertEqual(try valueText(.memory, in: missing), "—")
    }

    func testMemoryPercentIsClampedAndRejectsNonFiniteInput() {
        XCTAssertEqual(ProcessSummaryStripView.memoryPercent(used: 1, total: 4), 25)
        XCTAssertEqual(ProcessSummaryStripView.memoryPercent(used: 8, total: 4), 100)
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: .nan, total: 4))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: .infinity, total: 4))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: 1, total: .nan))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: 1, total: .infinity))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: 1, total: 0))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: 1, total: nil))
        XCTAssertNil(ProcessSummaryStripView.memoryPercent(used: 1e308, total: 1e-300))
    }

    // MARK: Helpers

    private func snapshot(memoryUsed: MetricReading, memoryTotal: MetricReading) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let original = base.system
        let system = SystemMetricsSnapshot(
            capacityCores: original.capacityCores, cpuPercent: original.cpuPercent,
            perCoreCPUPercent: original.perCoreCPUPercent,
            memoryUsedBytes: memoryUsed, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: memoryTotal, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: original.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: original.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: original.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: original.networkTransmitBytesPerSecond,
            networkInterfaces: [])
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: [],
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                  capabilities: [:])
    }

    /// The value text shown in one tile: the text field that is not the tile's title.
    private func valueText(_ metric: PerformanceMetric, in strip: ProcessSummaryStripView) throws -> String {
        let tile = try XCTUnwrap(descendant(withIdentifier: "processes.summary.\(metric.rawValue)", in: strip),
                                 "missing tile for \(metric.rawValue)")
        let fields = textFields(in: tile).filter { $0.stringValue != metric.title }
        return try XCTUnwrap(fields.first?.stringValue, "missing value label for \(metric.rawValue)")
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: subview) { return match }
        }
        return nil
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
    }
}
