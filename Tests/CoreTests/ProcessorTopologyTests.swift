import Darwin
import XCTest
@testable import Microgravity

final class ProcessorTopologyTests: XCTestCase {
    private func cpus(_ range: Range<Int>, _ clusterType: String) -> [(logicalID: Int, clusterType: String)] {
        range.map { (logicalID: $0, clusterType: clusterType) }
    }

    func testM5ProShapeMapsSuperAndPerformanceByLogicalCount() {
        // Level 0 "Super" has 6 CPUs and the "P" cluster type; level 1 "Performance" has 12 CPUs across two "M" clusters.
        let topology = ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(12..<18, "P") + cpus(0..<12, "M"),
            logicalCPUCount: 18)

        XCTAssertEqual(topology, ProcessorTopology(kinds: [
            ProcessorCoreKind(name: "Super", rank: 0, logicalCPUs: Array(12..<18)),
            ProcessorCoreKind(name: "Performance", rank: 1, logicalCPUs: Array(0..<12)),
        ]))
    }

    func testM1ProShapeMapsPerformanceAndEfficiency() {
        let topology = ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Performance", logicalCount: 8), (name: "Efficiency", logicalCount: 2)],
            cpus: cpus(2..<10, "P") + cpus(0..<2, "E"),
            logicalCPUCount: 10)

        XCTAssertEqual(topology, ProcessorTopology(kinds: [
            ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: Array(2..<10)),
            ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [0, 1]),
        ]))
    }

    func testM1BaseShapeWithEqualCountsMapsByLetterOrder() {
        // Base M1 through M4 chips report 4 Performance and 4 Efficiency CPUs. Letters known: P is stronger than E.
        let topology = ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Performance", logicalCount: 4), (name: "Efficiency", logicalCount: 4)],
            cpus: cpus(4..<8, "P") + cpus(0..<4, "E"),
            logicalCPUCount: 8)

        XCTAssertEqual(topology, ProcessorTopology(kinds: [
            ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: Array(4..<8)),
            ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: Array(0..<4)),
        ]))
    }

    func testKnownLettersWhoseCountsDisagreeResolveToNil() {
        // The letters are known, so there is no fallback. P has 6 CPUs but the first level claims 5.
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 5), (name: "Performance", logicalCount: 13)],
            cpus: cpus(12..<18, "P") + cpus(0..<12, "M"),
            logicalCPUCount: 18))
    }

    func testUnknownLetterWithUniqueCountsResolvesThroughFallback() {
        // "Q" and "Z" are not known letters, so the unique-count match decides the mapping.
        let topology = ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Performance", logicalCount: 12), (name: "Efficiency", logicalCount: 6)],
            cpus: cpus(0..<6, "Q") + cpus(6..<18, "Z"),
            logicalCPUCount: 18)

        XCTAssertEqual(topology, ProcessorTopology(kinds: [
            ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: Array(6..<18)),
            ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: Array(0..<6)),
        ]))
    }

    func testUnknownLetterWithEqualCountsResolvesToNil() {
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Performance", logicalCount: 4), (name: "Efficiency", logicalCount: 4)],
            cpus: cpus(4..<8, "X") + cpus(0..<4, "Y"),
            logicalCPUCount: 8))
    }

    func testSingleLevelAndNoLevelsResolveToNil() {
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "CPU", logicalCount: 8)],
            cpus: cpus(0..<8, "X"),
            logicalCPUCount: 8))
        XCTAssertNil(ProcessorTopologyReader.resolve(perfLevels: [], cpus: cpus(0..<8, "X"), logicalCPUCount: 8))
    }

    func testCPUCountDisagreeingWithLogicalCountResolvesToNil() {
        // Only 17 CPUs are described for an 18-CPU machine.
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(0..<12, "M") + cpus(12..<17, "P"),
            logicalCPUCount: 18))
    }

    func testGroupCountsNotMatchingLevelCountsResolveToNil() {
        // The levels sum to 17 but the device tree groups are 12 and 6.
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 11)],
            cpus: cpus(0..<12, "M") + cpus(12..<18, "P"),
            logicalCPUCount: 18))
    }

    func testDuplicateLogicalIDResolvesToNil() {
        // ID 3 appears twice and ID 17 is missing, even though the count is right.
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(0..<12, "M") + cpus(12..<17, "P") + [(logicalID: 3, clusterType: "P")],
            logicalCPUCount: 18))
    }

    func testMissingLogicalIDResolvesToNil() {
        // ID 18 is outside 0..<18, so ID 17 is effectively missing.
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(0..<12, "M") + cpus(12..<17, "P") + [(logicalID: 18, clusterType: "P")],
            logicalCPUCount: 18))
    }

    func testEmptyClusterTypeOrLevelNameResolvesToNil() {
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "Super", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(0..<6, "") + cpus(6..<18, "M"),
            logicalCPUCount: 18))
        XCTAssertNil(ProcessorTopologyReader.resolve(
            perfLevels: [(name: "", logicalCount: 6), (name: "Performance", logicalCount: 12)],
            cpus: cpus(12..<18, "P") + cpus(0..<12, "M"),
            logicalCPUCount: 18))
    }

    func testLiveReadMatchesThisMacsPerformanceLevels() throws {
        let logicalCPUCount = try XCTUnwrap(sysctlInt("hw.logicalcpu"))
        // Single-class Macs and any failed source read as nil, which the UI treats as one ungrouped list.
        guard let topology = ProcessorTopologyReader.read() else { return }

        XCTAssertGreaterThanOrEqual(topology.kinds.count, 2)
        XCTAssertEqual(topology.kinds.map(\.rank), Array(0..<topology.kinds.count))
        XCTAssertTrue(topology.kinds.allSatisfy { !$0.name.isEmpty && $0.logicalCPUs == $0.logicalCPUs.sorted() })
        XCTAssertEqual(topology.kinds.flatMap(\.logicalCPUs).sorted(), Array(0..<logicalCPUCount))
        for kind in topology.kinds {
            XCTAssertEqual(kind.logicalCPUs.count, try XCTUnwrap(sysctlInt("hw.perflevel\(kind.rank).logicalcpu")))
        }
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return Int(value)
    }
}
