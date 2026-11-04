import XCTest
@testable import Microgravity

final class CounterDeltaTrackerTests: XCTestCase {
    func testFirstSampleIsUnavailableUntilBaselineExists() {
        var tracker = CounterDeltaTracker<String>()
        let first = tracker.update(100, for: "disk", at: date(0))

        XCTAssertEqual(first, .baseline)
        XCTAssertEqual(tracker.update(160, for: "disk", at: date(2)), .delta(value: 60, elapsed: 2))
    }

    func testCounterResetRebasesInsteadOfReportingNegativeOrHugeRate() {
        var tracker = CounterDeltaTracker<String>()
        _ = tracker.update(1_000, for: "en0", at: date(0))

        XCTAssertEqual(tracker.update(3, for: "en0", at: date(1)), .counterReset)
        XCTAssertEqual(tracker.update(23, for: "en0", at: date(2)), .delta(value: 20, elapsed: 1))
    }

    func testLongSleepGapRebasesWithoutSmearingTrafficAcrossSleep() {
        var tracker = CounterDeltaTracker<String>(maximumInterval: 10)
        _ = tracker.update(1_000, for: "disk", at: date(0))

        XCTAssertEqual(tracker.update(9_000, for: "disk", at: date(11)), .sleepGap)
        XCTAssertEqual(tracker.update(9_025, for: "disk", at: date(12)), .delta(value: 25, elapsed: 1))
    }

    func testInvalidTimestampDoesNotReplaceGoodBaseline() {
        var tracker = CounterDeltaTracker<String>()
        _ = tracker.update(100, for: "disk", at: date(5))

        XCTAssertEqual(tracker.update(150, for: "disk", at: date(4)), .invalidTimestamp)
        XCTAssertEqual(tracker.update(160, for: "disk", at: date(6)), .delta(value: 60, elapsed: 1))
    }

    func testReusedPIDStartsASeparateCounterStream() {
        let old = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        let reused = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_100, microseconds: 0))
        var tracker = CounterDeltaTracker<ProcessIdentity>()
        _ = tracker.update(50_000, for: old, at: date(0))

        XCTAssertEqual(tracker.update(4, for: reused, at: date(1)), .baseline)
        XCTAssertEqual(tracker.update(14, for: reused, at: date(2)), .delta(value: 10, elapsed: 1))
    }

    func testExitedProcessStreamCanBeDiscarded() {
        let identity = ProcessIdentity(pid: 88, startTime: .init(secondsSinceEpoch: 1_800_000_000, microseconds: 0))
        var tracker = CounterDeltaTracker<ProcessIdentity>()
        _ = tracker.update(50, for: identity, at: date(0))

        tracker.remove(identity)

        XCTAssertEqual(tracker.update(90, for: identity, at: date(1)), .baseline)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }
}
