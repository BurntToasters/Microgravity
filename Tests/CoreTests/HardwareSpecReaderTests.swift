import Foundation
import XCTest
@testable import Microgravity

final class HardwareSpecReaderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTwoReadsReturnEqualSnapshots() {
        let recorder = LookupRecorder()
        let reader = HardwareSpecReader(
            networkDetailLookup: { recorder.lookup($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let interface = makeInterface(name: "en0", at: start)

        let first = reader.read(primaryNetworkInterface: interface)
        let second = reader.read(primaryNetworkInterface: interface)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.primaryNetworkInterface, "en0")
        XCTAssertEqual(second.primaryNetworkDetail, "en0 detail 1")
    }

    func testNetworkDetailCacheIsReusedWithinTTLAndRefreshedAfterIt() {
        let recorder = LookupRecorder()
        let clock = TestClock(start)
        let reader = HardwareSpecReader(
            networkDetailLookup: { recorder.lookup($0) },
            now: { clock.now }
        )
        let interface = makeInterface(name: "en0", at: start)

        let initial = reader.read(primaryNetworkInterface: interface)
        XCTAssertEqual(recorder.count(for: "en0"), 1)
        XCTAssertEqual(initial.primaryNetworkDetail, "en0 detail 1")

        // Inside the 30 s TTL: the lookup must not run again.
        clock.advance(by: 10)
        _ = reader.read(primaryNetworkInterface: interface)
        clock.advance(by: 15)
        let reused = reader.read(primaryNetworkInterface: interface)
        XCTAssertEqual(recorder.count(for: "en0"), 1)
        XCTAssertEqual(reused.primaryNetworkDetail, "en0 detail 1")

        // Past the TTL (35 s after the first lookup): the lookup runs again and the new value is returned.
        clock.advance(by: 10)
        let refreshed = reader.read(primaryNetworkInterface: interface)
        XCTAssertEqual(recorder.count(for: "en0"), 2)
        XCTAssertEqual(refreshed.primaryNetworkDetail, "en0 detail 2")
    }

    func testNetworkDetailIsCachedPerInterfaceName() {
        let recorder = LookupRecorder()
        let clock = TestClock(start)
        let reader = HardwareSpecReader(
            networkDetailLookup: { recorder.lookup($0) },
            now: { clock.now }
        )

        let en0 = reader.read(primaryNetworkInterface: makeInterface(name: "en0", at: start))
        clock.advance(by: 5)
        let en1 = reader.read(primaryNetworkInterface: makeInterface(name: "en1", at: clock.now))
        clock.advance(by: 5)
        _ = reader.read(primaryNetworkInterface: makeInterface(name: "en0", at: clock.now))

        XCTAssertEqual(en0.primaryNetworkDetail, "en0 detail 1")
        XCTAssertEqual(en1.primaryNetworkDetail, "en1 detail 1")
        XCTAssertEqual(recorder.count(for: "en0"), 1)
        XCTAssertEqual(recorder.count(for: "en1"), 1)
    }

    func testReadWithoutInterfaceDoesNotRunNetworkLookup() {
        let recorder = LookupRecorder()
        let reader = HardwareSpecReader(
            networkDetailLookup: { recorder.lookup($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        _ = reader.read()

        XCTAssertEqual(recorder.totalCount, 0)
    }

    private func makeInterface(name: String, at date: Date) -> NetworkInterfaceSnapshot {
        let rate = MetricReading(value: 100, unit: .bytesPerSecond, timestamp: date)
        let total = MetricReading(value: 1_000, unit: .bytes, timestamp: date)
        return NetworkInterfaceSnapshot(
            name: name, isUp: true,
            receiveBytesPerSecond: rate, transmitBytesPerSecond: rate,
            receiveTotalBytes: total, transmitTotalBytes: total
        )
    }
}

/// Records lookup calls and answers "<name> detail <n>", where n counts calls for that name.
private final class LookupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    func lookup(_ name: String) -> String {
        lock.withLock {
            let number = (calls[name] ?? 0) + 1
            calls[name] = number
            return "\(name) detail \(number)"
        }
    }

    func count(for name: String) -> Int {
        lock.withLock { calls[name] ?? 0 }
    }

    var totalCount: Int {
        lock.withLock { calls.values.reduce(0, +) }
    }
}

/// A clock the test moves forward explicitly.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
