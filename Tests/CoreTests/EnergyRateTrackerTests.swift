import Foundation
import XCTest
@testable import Microgravity

final class EnergyRateTrackerTests: XCTestCase {
    private func tick(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: Date(timeIntervalSinceReferenceDate: start),
                     end: Date(timeIntervalSinceReferenceDate: end))
    }

    /// Feeds `count` consecutive ticks of `length` seconds; `joules(index)` is the energy delta of tick `index`.
    private func run(ticks count: Int, length: TimeInterval, joules: (Int) -> Double) -> [Double?] {
        var tracker = EnergyRateTracker()
        return (0..<count).map { index in
            tracker.update(joules(index), interval: tick(Double(index) * length, Double(index + 1) * length))
        }
    }

    private func assertWatts(_ values: [Double?], _ expected: [Double?], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.count, expected.count, file: file, line: line)
        for (index, pair) in zip(values, expected).enumerated() {
            switch (pair.0, pair.1) {
            case (nil, nil):
                continue
            case let (actual?, wanted?):
                XCTAssertEqual(actual, wanted, accuracy: 1e-9, "tick \(index)", file: file, line: line)
            default:
                XCTFail("tick \(index): got \(String(describing: pair.0)), expected \(String(describing: pair.1))",
                        file: file, line: line)
            }
        }
    }

    func testCounterRefreshingEveryTickReportsRateAfterOneWarmUpTick() {
        // 10 W at 1 s ticks: 10 J per tick.
        let values = run(ticks: 4, length: 1) { _ in 10 }

        assertWatts(values, [nil, 10, 10, 10])
    }

    func testTwoSecondRefreshAtOneSecondTicksHoldsRealPowerInsteadOfAlternating() {
        // 10 W, counter refreshes at t = 2, 4, 6 ... with 20 J each time (ticks with odd index).
        let values = run(ticks: 8, length: 1) { $0 % 2 == 1 ? 20 : 0 }

        assertWatts(values, [nil, nil, nil, 10, 10, 10, 10, 10])
    }

    func testHalfSecondTicksWithFastCounterReportRate() {
        // 5 W at 0.5 s ticks: 2.5 J per tick.
        let values = run(ticks: 4, length: 0.5) { _ in 2.5 }

        assertWatts(values, [nil, 5, 5, 5])
    }

    func testTwoSecondRefreshAtHalfSecondTicksHoldsRateBetweenRefreshes() {
        // 5 W, refresh every 2 s (every 4th tick of 0.5 s) with 10 J each time.
        let values = run(ticks: 12, length: 0.5) { ($0 + 1) % 4 == 0 ? 10 : 0 }

        assertWatts(values, [nil, nil, nil, nil, nil, nil, nil, 5, 5, 5, 5, 5])
    }

    func testAlwaysZeroReportsZeroFromFiveSecondsOfIdle() {
        let values = run(ticks: 10, length: 1) { _ in 0 }

        // Idle starts at t = 0. The first zero is at t = 6 (more than 5 s since idle began).
        assertWatts(values, [nil, nil, nil, nil, nil, 0, 0, 0, 0, 0])
    }

    func testWakeAfterIdleAnchorsWithoutSpikeAndThenReportsRate() {
        var tracker = EnergyRateTracker()
        var values: [Double?] = []

        // Active at 10 W for four ticks (t = 0...4).
        for index in 0..<4 {
            values.append(tracker.update(10, interval: tick(Double(index), Double(index + 1))))
        }
        // Idle from t = 4 for ten ticks. The held 10 W drops to 0 once more than 5 s have passed since t = 4.
        for index in 4..<14 {
            values.append(tracker.update(0, interval: tick(Double(index), Double(index + 1))))
        }
        // Wake: the first energy tick only anchors, then the rate comes back.
        for index in 14..<16 {
            values.append(tracker.update(10, interval: tick(Double(index), Double(index + 1))))
        }

        assertWatts(values, [nil, 10, 10, 10,
                             10, 10, 10, 10, 10,
                             0, 0, 0, 0, 0,
                             0, 10])
    }

    func testTickLengthChangeForFastCounterUsesCurrentTickLength() {
        var tracker = EnergyRateTracker()
        var values: [Double?] = []

        values.append(tracker.update(10, interval: tick(0, 1)))
        values.append(tracker.update(10, interval: tick(1, 2)))
        values.append(tracker.update(20, interval: tick(2, 4)))   // 2 s tick at 10 W
        values.append(tracker.update(5, interval: tick(4, 4.5)))  // 0.5 s tick at 10 W

        assertWatts(values, [nil, 10, 10, 10])
    }

    func testRoleForChannelNames() {
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "CPU Energy"), .cpu)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "GPU Energy"), .gpu)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "ANE0"), .ane)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "DRAM0"), .dram)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "DIE_0_CPU Energy"), .cpu)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "ECPU"), .cpuCluster)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "PCPU1"), .cpuCluster)
        XCTAssertEqual(EnergyChannelRole.role(forChannelName: "MCPU1"), .cpuCluster)
    }

    func testChannelsWithoutRoleAreIgnoredSoNothingIsCountedTwice() {
        XCTAssertNil(EnergyChannelRole.role(forChannelName: "GPU0"))
        XCTAssertNil(EnergyChannelRole.role(forChannelName: "PCPUDTL0"))
        XCTAssertNil(EnergyChannelRole.role(forChannelName: "MCPU0_0"))
        XCTAssertNil(EnergyChannelRole.role(forChannelName: "PACC_0"))
        XCTAssertNil(EnergyChannelRole.role(forChannelName: ""))
    }
}
