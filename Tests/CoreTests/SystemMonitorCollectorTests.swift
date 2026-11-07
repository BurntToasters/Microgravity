import XCTest
import Darwin
@testable import Microgravity

private struct FixedAdvancedMetricsCollector: AdvancedMetricsCollecting {
    let snapshot: AdvancedMetricsSnapshot

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        snapshot
    }
}

final class SystemMonitorCollectorTests: XCTestCase {
    func testProcessIdentityCoverageMarksUnreadableInitialIdentityIncomplete() {
        var coverage = ProcessIdentityCoverage()

        XCTAssertFalse(coverage.include(initial: nil, revalidated: nil))
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.omissions, [.initialIdentityUnavailable])
    }

    func testProcessIdentityCoverageMarksFailedOrChangedRevalidationIncomplete() {
        let identity = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let reusedIdentity = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_001, microseconds: 0))
        var coverage = ProcessIdentityCoverage()

        XCTAssertFalse(coverage.include(initial: identity, revalidated: nil))
        XCTAssertFalse(coverage.include(initial: identity, revalidated: reusedIdentity))
        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.omissions, [.revalidationUnavailable, .identityChanged])
    }

    func testProcessIdentityCoverageKeepsStableIdentityComplete() {
        let identity = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        var coverage = ProcessIdentityCoverage()

        XCTAssertTrue(coverage.include(initial: identity, revalidated: identity))
        XCTAssertTrue(coverage.complete)
        XCTAssertTrue(coverage.omissions.isEmpty)
    }

    func testMemoryBreakdownCountsReclaimableInternalAndAvoidsCachePageOverlap() {
        let memory = SystemMonitorCollector.memoryBreakdown(
            physicalBytes: 10_000, pageBytes: 10,
            internalPages: 800, purgeablePages: 200,
            wirePages: 150, compressorPages: 50)

        XCTAssertEqual(memory.usedBytes, 8_000)
        XCTAssertEqual(memory.availableBytes, 2_000)
    }

    func testMemoryBreakdownClampsUsedBytesToPhysicalMemory() {
        let memory = SystemMonitorCollector.memoryBreakdown(
            physicalBytes: 1_000, pageBytes: 10,
            internalPages: 100, purgeablePages: 0,
            wirePages: 100, compressorPages: 100)

        XCTAssertEqual(memory.usedBytes, 1_000)
        XCTAssertEqual(memory.availableBytes, 0)
    }

    func testCurrentProcessHasAReadablePhysicalFootprint() async {
        let snapshot = await SystemMonitorCollector().collect(at: Date())
        let currentPID = Int32(getpid())

        guard let currentProcess = snapshot.processes.first(where: { $0.id.pid == currentPID }) else {
            XCTFail("the live collector must include its own process")
            return
        }

        XCTAssertGreaterThan(currentProcess.memoryBytes.value ?? 0, 0,
                             "proc_pid_rusage must fill a correctly sized rusage_info_v4 buffer")
    }

    func testCombineRatesSumsAvailableMembersAndReportsPartialAvailability() {
        let timestamp = Date()
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(value: 10, unit: .percent, timestamp: timestamp),
            MetricReading(unavailable: .percent, timestamp: timestamp,
                          reason: .permissionDenied, detail: "denied"),
            MetricReading(value: 32.5, unit: .percent, timestamp: timestamp),
        ], unit: .percent, timestamp: timestamp)

        XCTAssertEqual(reading.value, 42.5)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertTrue(reading.isPartial)
        XCTAssertTrue(reading.detail?.contains("denied") == true)
        XCTAssertTrue(reading.detail?.contains("Partial: 1 of 3 members unavailable") == true)
    }

    func testCombineRatesReturnsPreferredReasonWhenAllMembersAreUnavailable() {
        let timestamp = Date()
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(unavailable: .bytes, timestamp: timestamp,
                          reason: .permissionDenied, detail: "first denial"),
            MetricReading(unavailable: .bytes, timestamp: timestamp, reason: .collectionFailed),
        ], unit: .bytes, timestamp: timestamp)

        XCTAssertNil(reading.value, "an all-unavailable group must not invent a zero total")
        XCTAssertEqual(reading.unavailableReason, .permissionDenied)
        XCTAssertEqual(reading.detail, "first denial")
        XCTAssertFalse(reading.isPartial, "without any measured contributors there is no lower-bound value")
    }

    func testCombineRatesPrioritizesCollectionFailuresOverUnsupportedMembers() {
        let timestamp = Date()
        let unsupported = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                        reason: .unsupported, detail: "metric unsupported")

        for reason in [MetricUnavailableReason.permissionDenied, .collectionFailed] {
            let detail = "source reported \(reason.rawValue)"
            let reading = SystemMonitorCollector.combineRates([
                unsupported,
                MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                              reason: reason, detail: detail),
            ], unit: .bytesPerSecond, timestamp: timestamp)

            XCTAssertEqual(reading.unavailableReason, reason)
            XCTAssertEqual(reading.detail, detail)
        }
    }

    func testCombineRatesSumsFullyAvailableMembersWithoutPartialDetail() {
        let timestamp = Date()
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(value: 1.5, unit: .bytesPerSecond, timestamp: timestamp),
            MetricReading(value: 2.5, unit: .bytesPerSecond, timestamp: timestamp),
        ], unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertEqual(reading.value, 4)
        XCTAssertNil(reading.unavailableReason)
        XCTAssertNil(reading.detail)
        XCTAssertFalse(reading.isPartial)
    }

    func testCombineRatesPreservesPartialInputAndItsDetail() {
        let timestamp = Date()
        let partial = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp,
                                    detail: "one contributor was incomplete", isPartial: true)
        let reading = SystemMonitorCollector.combineRates([
            partial,
            MetricReading(value: 2, unit: .bytesPerSecond, timestamp: timestamp),
        ], unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertEqual(reading.value, 2, "a partial measured zero must remain available and add as zero")
        XCTAssertTrue(reading.isPartial)
        XCTAssertEqual(reading.detail, "one contributor was incomplete")
    }

    func testCombineRatesPreservesSharedMeasurementInterval() {
        let timestamp = Date()
        let interval = DateInterval(start: timestamp.addingTimeInterval(-2), end: timestamp)
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(value: 1, unit: .bytesPerSecond, timestamp: timestamp,
                          measurementInterval: interval),
            MetricReading(value: 2, unit: .bytesPerSecond, timestamp: timestamp,
                          measurementInterval: interval),
        ], unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertEqual(reading.measurementInterval, interval)
        XCTAssertFalse(reading.isPartial)
    }

    func testCombineRatesDropsMeasurementIntervalWhenContributorsDiffer() {
        let timestamp = Date()
        let firstInterval = DateInterval(start: timestamp.addingTimeInterval(-2), end: timestamp)
        let secondInterval = DateInterval(start: timestamp.addingTimeInterval(-3), end: timestamp)
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(value: 1, unit: .bytesPerSecond, timestamp: timestamp,
                          measurementInterval: firstInterval),
            MetricReading(value: 2, unit: .bytesPerSecond, timestamp: timestamp,
                          measurementInterval: secondInterval),
        ], unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertNil(reading.measurementInterval)
        XCTAssertTrue(reading.isPartial)
        XCTAssertTrue(reading.detail?.contains("incompatible measurement intervals") == true)

        let partlyTimed = SystemMonitorCollector.combineRates([
            MetricReading(value: 1, unit: .bytesPerSecond, timestamp: timestamp,
                          measurementInterval: firstInterval),
            MetricReading(value: 2, unit: .bytesPerSecond, timestamp: timestamp),
        ], unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertNil(partlyTimed.measurementInterval)
        XCTAssertTrue(partlyTimed.isPartial)
    }

    func testCombineRatesReportsEmptyGroupsAsNotCollected() {
        let reading = SystemMonitorCollector.combineRates([], unit: .percent, timestamp: Date())

        XCTAssertNil(reading.value)
        XCTAssertEqual(reading.unavailableReason, .notCollected)
    }

    func testRepeatedCollectKeepsCurrentProcessFootprintReadable() async {
        let collector = SystemMonitorCollector()
        let currentPID = Int32(getpid())
        let first = Date()
        let second = first.addingTimeInterval(1)

        let firstSnapshot = await collector.collect(at: first)
        let secondSnapshot = await collector.collect(at: second)

        for snapshot in [firstSnapshot, secondSnapshot] {
            guard let currentProcess = snapshot.processes.first(where: { $0.id.pid == currentPID }) else {
                XCTFail("the live collector must include its own process on every collect")
                return
            }
            XCTAssertGreaterThan(currentProcess.memoryBytes.value ?? 0, 0,
                                 "a repeated collect must still read a nonzero footprint without crashing")
        }
    }

    func testAdvancedPerProcessFallbackUsesCapabilityReasonAndPreservesReadings() async {
        let timestamp = Date()
        let initial = await SystemMonitorCollector().collect(at: timestamp)
        guard let currentProcess = initial.processes.first(where: { $0.id.pid == Int32(getpid()) }) else {
            XCTFail("the live collector must include its own process")
            return
        }
        XCTAssertEqual(currentProcess.advancedMetrics[.processGPUTime]?.unavailableReason, .unsupported)

        let realNetworkReading = MetricReading(value: 12.5, unit: .bytesPerSecond, timestamp: timestamp)
        let advanced = AdvancedMetricsSnapshot(
            perProcess: [currentProcess.id: [.processNetworkTransmit: realNetworkReading]],
            capabilities: [
                .processNetwork: MetricAvailability(available: true),
                .processNetworkReceive: MetricAvailability(available: false, reason: .permissionDenied,
                                                           detail: "network counters are restricted"),
                .processNetworkTransmit: MetricAvailability(available: true),
                .processGPUTime: MetricAvailability(available: true),
            ])
        let result = await SystemMonitorCollector(advancedCollector: FixedAdvancedMetricsCollector(snapshot: advanced))
            .collect(at: timestamp)

        guard let process = result.processes.first(where: { $0.id == currentProcess.id }) else {
            XCTFail("the live collector must include the same process identity on the next sample")
            return
        }
        let receive = process.advancedMetrics[.processNetworkReceive]
        XCTAssertEqual(receive?.unit, .bytesPerSecond)
        XCTAssertEqual(receive?.unavailableReason, .permissionDenied)
        XCTAssertEqual(receive?.detail, "network counters are restricted")

        let transmit = process.advancedMetrics[.processNetworkTransmit]
        XCTAssertEqual(transmit, realNetworkReading, "a real provider reading must not be replaced by fallback data")

        let totalNetwork = process.advancedMetrics[.processNetwork]
        XCTAssertEqual(totalNetwork?.unit, .bytesPerSecond)
        XCTAssertEqual(totalNetwork?.unavailableReason, .notCollected,
                       "an available capability without a row must not imply an unsupported metric")

        let gpuTime = process.advancedMetrics[.processGPUTime]
        XCTAssertEqual(gpuTime?.unit, .seconds)
        XCTAssertEqual(gpuTime?.unavailableReason, .notCollected)
    }
}
