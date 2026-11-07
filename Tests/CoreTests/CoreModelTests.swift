import XCTest
@testable import Microgravity

final class CoreModelTests: XCTestCase {
    func testUnavailableReadingIsNotAZeroMeasurement() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let unavailable = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                        reason: .permissionDenied, detail: "stats denied")
        let measuredZero = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)

        XCTAssertNil(unavailable.value)
        XCTAssertEqual(unavailable.unit, .bytesPerSecond)
        XCTAssertEqual(unavailable.timestamp, timestamp)
        XCTAssertEqual(unavailable.unavailableReason, .permissionDenied)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(measuredZero.value, 0)
        XCTAssertTrue(measuredZero.isAvailable)
    }

    func testMetricReadingDecodesLegacyDataWithoutPartialFlag() throws {
        let legacy = Data(#"{"value":12.5,"unit":"bytesPerSecond","timestamp":1800000000,"unavailableReason":null,"detail":"legacy"}"#.utf8)

        let reading = try JSONDecoder().decode(MetricReading.self, from: legacy)

        XCTAssertEqual(reading.value, 12.5)
        XCTAssertEqual(reading.detail, "legacy")
        XCTAssertFalse(reading.isPartial)
        XCTAssertNil(reading.measurementInterval)
    }

    func testPartialMetricReadingCodableRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = MetricReading(value: 12.5, unit: .bytesPerSecond, timestamp: timestamp,
                                    detail: "one interface unavailable", isPartial: true,
                                    measurementInterval: DateInterval(start: timestamp.addingTimeInterval(-5),
                                                                      end: timestamp))

        let decoded = try JSONDecoder().decode(MetricReading.self, from: JSONEncoder().encode(reading))

        XCTAssertEqual(decoded, reading)
        XCTAssertTrue(decoded.isPartial)
        XCTAssertEqual(decoded.measurementInterval?.duration, 5)
    }

    func testPIDReuseHasDifferentProcessIdentity() {
        let old = ProcessIdentity(pid: 415, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 4))
        let reused = ProcessIdentity(pid: 415, startTime: .init(secondsSinceEpoch: 1_800_000_001, microseconds: 4))

        XCTAssertNotEqual(old, reused)
        XCTAssertEqual(Set([old, reused]).count, 2)
    }

    func testAdvancedMetricsRetainTheirUnitsInGraphSamples() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let system = CoreTestFixtures.system(timestamp: timestamp)
        let gpu = MetricReading(value: 16.5, unit: .wattHours, timestamp: timestamp)
        let unavailableEnergy = MetricReading(unavailable: .watts, timestamp: timestamp,
                                              reason: .unsupported)
        let snapshot = MonitoringSnapshot(timestamp: timestamp, system: system, processes: [],
                                          processGroups: [], startupItems: [], services: [], users: [],
                                          discoveryCoverage: [:], capabilities: [:],
                                          advancedMetrics: [.gpu: gpu, .energy: unavailableEnergy])

        let graph = MonitoringGraphSample(snapshot: snapshot)

        XCTAssertEqual(graph.advancedMetrics[.gpu]?.value, 16.5)
        XCTAssertEqual(graph.advancedMetrics[.gpu]?.unit, .wattHours)
        XCTAssertEqual(graph.advancedMetrics[.energy]?.unavailableReason, .unsupported)
    }
}

enum CoreTestFixtures {
    static func reading(_ value: Double = 0, unit: MetricUnit, timestamp: Date) -> MetricReading {
        MetricReading(value: value, unit: unit, timestamp: timestamp)
    }

    static func system(timestamp: Date) -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            capacityCores: 4,
            cpuPercent: reading(0, unit: .percent, timestamp: timestamp),
            perCoreCPUPercent: [reading(0, unit: .percent, timestamp: timestamp)],
            memoryUsedBytes: reading(0, unit: .bytes, timestamp: timestamp),
            memoryAvailableBytes: reading(0, unit: .bytes, timestamp: timestamp),
            memoryTotalBytes: reading(16_000_000_000, unit: .bytes, timestamp: timestamp),
            memoryPressure: .init(level: .normal, timestamp: timestamp),
            swapUsedBytes: reading(0, unit: .bytes, timestamp: timestamp),
            swapTotalBytes: reading(0, unit: .bytes, timestamp: timestamp),
            diskReadBytesPerSecond: reading(0, unit: .bytesPerSecond, timestamp: timestamp),
            diskWriteBytesPerSecond: reading(0, unit: .bytesPerSecond, timestamp: timestamp),
            networkReceiveBytesPerSecond: reading(0, unit: .bytesPerSecond, timestamp: timestamp),
            networkTransmitBytesPerSecond: reading(0, unit: .bytesPerSecond, timestamp: timestamp),
            networkInterfaces: [])
    }

    static func snapshot(timestamp: Date, cpuPercent: Double = 0,
                         diskReadRate: Double = 0, diskWriteRate: Double = 0,
                         networkReceiveRate: Double = 0, networkTransmitRate: Double = 0,
                         cpuReason: MetricUnavailableReason? = nil) -> MonitoringSnapshot {
        let base = system(timestamp: timestamp)
        let cpu = cpuReason.map {
            MetricReading(unavailable: .percent, timestamp: timestamp, reason: $0)
        } ?? reading(cpuPercent, unit: .percent, timestamp: timestamp)
        let system = SystemMetricsSnapshot(
            capacityCores: base.capacityCores,
            cpuPercent: cpu,
            perCoreCPUPercent: base.perCoreCPUPercent,
            memoryUsedBytes: base.memoryUsedBytes,
            memoryAvailableBytes: base.memoryAvailableBytes,
            memoryTotalBytes: base.memoryTotalBytes,
            memoryPressure: base.memoryPressure,
            swapUsedBytes: base.swapUsedBytes,
            swapTotalBytes: base.swapTotalBytes,
            diskReadBytesPerSecond: reading(diskReadRate, unit: .bytesPerSecond, timestamp: timestamp),
            diskWriteBytesPerSecond: reading(diskWriteRate, unit: .bytesPerSecond, timestamp: timestamp),
            networkReceiveBytesPerSecond: reading(networkReceiveRate, unit: .bytesPerSecond, timestamp: timestamp),
            networkTransmitBytesPerSecond: reading(networkTransmitRate, unit: .bytesPerSecond, timestamp: timestamp),
            networkInterfaces: [])
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: [],
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                  capabilities: [:])
    }
}
