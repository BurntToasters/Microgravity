import XCTest
import Darwin
@testable import Microgravity

final class SystemMonitorCollectorTests: XCTestCase {
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
        XCTAssertEqual(reading.detail, "Partial: 1 of 3 members unavailable")
    }

    func testCombineRatesReturnsFirstReasonWhenAllMembersAreUnavailable() {
        let timestamp = Date()
        let reading = SystemMonitorCollector.combineRates([
            MetricReading(unavailable: .bytes, timestamp: timestamp,
                          reason: .permissionDenied, detail: "first denial"),
            MetricReading(unavailable: .bytes, timestamp: timestamp, reason: .collectionFailed),
        ], unit: .bytes, timestamp: timestamp)

        XCTAssertNil(reading.value, "an all-unavailable group must not invent a zero total")
        XCTAssertEqual(reading.unavailableReason, .permissionDenied)
        XCTAssertEqual(reading.detail, "first denial")
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
}
