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
