import XCTest
import Darwin
@testable import Microgravity

/// Serves one prepared advanced snapshot per collect call, in order; the last one repeats.
private actor SequencedAdvancedMetricsCollector: AdvancedMetricsCollecting {
    private let snapshots: [AdvancedMetricsSnapshot]
    private var calls = 0

    init(snapshots: [AdvancedMetricsSnapshot]) {
        self.snapshots = snapshots
    }

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        defer { calls += 1 }
        return snapshots[min(calls, snapshots.count - 1)]
    }
}

/// Helper-sourced per-process counters must be rated by their capture time, not the collection tick.
/// Pid 1 is used because a normal user cannot read its task or resource usage, so the helper supplement applies.
final class HelperCounterTimeBaseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Ticks every 0.5 s; the helper captures every 1.0 s, so each capture serves two consecutive ticks.
    private let tickInterval: TimeInterval = 0.5
    private let captureInterval: TimeInterval = 1.0
    private let tickCount = 12

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(getuid() == 0, "Pid 1 is readable as root, so the helper supplement is not used.")
    }

    private func pid1Identity() throws -> ProcessIdentity {
        try XCTUnwrap(SystemMonitorCollector.processIdentityLookup().identities[1],
                      "launchd (pid 1) must be listed")
    }

    /// Capture `k` happens at `t0 + k` seconds, so ticks `2k` and `2k + 1` both see capture `k` (a repeated capture).
    private func captureIndex(forTick tick: Int) -> Int {
        Int(Double(tick) * tickInterval / captureInterval)
    }

    private func snapshots(for identity: ProcessIdentity,
                           cpuNanosPerCapture: UInt64,
                           diskReadPerCapture: UInt64,
                           diskWritePerCapture: UInt64) -> [AdvancedMetricsSnapshot] {
        (0..<tickCount).map { tick in
            let capture = captureIndex(forTick: tick)
            let capturedAt = t0.addingTimeInterval(Double(capture) * captureInterval)
            let metrics = CollectedProcessSystemMetrics(
                cpuTotalNanoseconds: UInt64(capture) * cpuNanosPerCapture,
                diskReadBytes: UInt64(capture) * diskReadPerCapture,
                diskWriteBytes: UInt64(capture) * diskWritePerCapture,
                capturedAt: capturedAt
            )
            return AdvancedMetricsSnapshot(perProcessSystemMetrics: [identity: metrics])
        }
    }

    private func collectTicks(_ snapshots: [AdvancedMetricsSnapshot]) async throws
        -> [(tick: Date, cores: Int, process: ProcessSnapshot)] {
        let identity = try pid1Identity()
        let collector = SystemMonitorCollector(advancedCollector: SequencedAdvancedMetricsCollector(snapshots: snapshots))
        var results: [(tick: Date, cores: Int, process: ProcessSnapshot)] = []
        for tick in 0..<tickCount {
            let timestamp = t0.addingTimeInterval(Double(tick) * tickInterval)
            let snapshot = await collector.collect(at: timestamp)
            let process = try XCTUnwrap(snapshot.processes.first { $0.id == identity },
                                        "pid 1 must be in tick \(tick)")
            results.append((timestamp, snapshot.system.capacityCores, process))
        }
        return results
    }

    func testHelperCPUIsRatedOverCaptureSpacing() async throws {
        let identity = try pid1Identity()
        // 0.5 s of CPU per 1.0 s capture interval.
        let ticks = try await collectTicks(snapshots(for: identity, cpuNanosPerCapture: 500_000_000,
                                                     diskReadPerCapture: 0, diskWritePerCapture: 0))
        let cores = try XCTUnwrap(ticks.first?.cores)
        XCTAssertGreaterThan(cores, 0)
        let expected = 0.5 / Double(cores) * 100

        // Tick 0 is the baseline; tick 1 repeats capture 0 and returns that same baseline reading.
        XCTAssertNil(ticks[0].process.cpuPercent.value)
        XCTAssertEqual(ticks[0].process.cpuPercent.unavailableReason, .warmingUp)
        XCTAssertNil(ticks[1].process.cpuPercent.value)
        XCTAssertEqual(ticks[1].process.cpuPercent.unavailableReason, .warmingUp)

        // After warm-up every tick reads the true rate, never 0 and never double.
        for tick in 2..<tickCount {
            let reading = ticks[tick].process.cpuPercent
            let value = try XCTUnwrap(reading.value, "tick \(tick) CPU should be available")
            XCTAssertEqual(value, expected, accuracy: 1e-6, "tick \(tick)")
            XCTAssertNotEqual(value, 0, "tick \(tick)")
            XCTAssertEqual(reading.measurementInterval?.duration ?? -1, captureInterval, accuracy: 1e-9,
                           "tick \(tick) must be rated over the capture spacing")
        }
    }

    func testRepeatedCaptureReturnsPreviousReading() async throws {
        let identity = try pid1Identity()
        // Tick 5 sees capture 2 again, the same capture that tick 4 rated.
        let ticks = try await collectTicks(snapshots(for: identity, cpuNanosPerCapture: 500_000_000,
                                                     diskReadPerCapture: 2_000_000, diskWritePerCapture: 500_000))
        let previous = ticks[4].process
        let repeated = ticks[5].process
        XCTAssertEqual(repeated.cpuPercent, previous.cpuPercent)
        XCTAssertEqual(repeated.diskReadBytesPerSecond, previous.diskReadBytesPerSecond)
        XCTAssertEqual(repeated.diskWriteBytesPerSecond, previous.diskWriteBytesPerSecond)
        XCTAssertEqual(repeated.cpuPercent.timestamp, t0.addingTimeInterval(2 * captureInterval),
                       "the reading keeps the capture time it was rated at")
        XCTAssertNotEqual(repeated.cpuPercent.value, 0)
        XCTAssertNotNil(repeated.cpuPercent.value)

        // The tick after the repeat rates capture 3 over the true spacing from capture 2.
        let cores = ticks[0].cores
        let expected = 0.5 / Double(cores) * 100
        let next = try XCTUnwrap(ticks[6].process.cpuPercent.value)
        XCTAssertEqual(next, expected, accuracy: 1e-6)
    }

    func testHelperDiskRatesUseCaptureSpacing() async throws {
        let identity = try pid1Identity()
        // 2 MB read and 0.5 MB written per 1.0 s capture interval.
        let ticks = try await collectTicks(snapshots(for: identity, cpuNanosPerCapture: 0,
                                                     diskReadPerCapture: 2_000_000,
                                                     diskWritePerCapture: 500_000))
        XCTAssertNil(ticks[0].process.diskReadBytesPerSecond.value)
        XCTAssertNil(ticks[0].process.diskWriteBytesPerSecond.value)

        for tick in 2..<tickCount {
            let read = try XCTUnwrap(ticks[tick].process.diskReadBytesPerSecond.value, "tick \(tick) read")
            let write = try XCTUnwrap(ticks[tick].process.diskWriteBytesPerSecond.value, "tick \(tick) write")
            XCTAssertEqual(read, 2_000_000, accuracy: 1e-6, "tick \(tick) read must be 2 MB/s, not 0 or 4 MB/s")
            XCTAssertEqual(write, 500_000, accuracy: 1e-6, "tick \(tick) write must be 0.5 MB/s, not 0 or 1 MB/s")
            XCTAssertEqual(ticks[tick].process.diskReadBytesPerSecond.unit, .bytesPerSecond)
        }
    }
}
