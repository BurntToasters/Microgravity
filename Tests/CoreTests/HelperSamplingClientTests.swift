import Foundation
import XCTest
@testable import Microgravity

final class HelperSamplingClientTests: XCTestCase {
    /// Counts status and requirement lookups and carries a fake uptime. Lock-guarded so the
    /// @Sendable closures handed to the client can use it from any isolation.
    private final class SamplingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var daemonEnabled = true
        private var requirementValue: String? = "anchor apple generic"
        private var uptime: TimeInterval = 1_000
        private var statusCount = 0
        private var requirementCount = 0

        func status() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            statusCount += 1
            return daemonEnabled
        }

        func requirement() -> String? {
            lock.lock()
            defer { lock.unlock() }
            requirementCount += 1
            return requirementValue
        }

        func currentUptime() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            uptime += seconds
        }

        func setDaemonEnabled(_ enabled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            daemonEnabled = enabled
        }

        func setRequirement(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            requirementValue = value
        }

        var statusCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return statusCount
        }

        var requirementCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return requirementCount
        }
    }

    private func makeClient(_ probe: SamplingProbe) -> HelperSamplingClient {
        HelperSamplingClient(daemonIsEnabled: { probe.status() },
                             signingRequirement: { probe.requirement() },
                             uptime: { probe.currentUptime() })
    }

    func testRepeatedRefreshesWithinFiveSecondsCheckStatusAndRequirementOnce() async {
        let probe = SamplingProbe()
        let client = makeClient(probe)
        for _ in 0..<10 {
            let ready = await client.prepareRefresh()
            XCTAssertTrue(ready)
            probe.advance(by: 0.4)
        }
        XCTAssertEqual(probe.statusCalls, 1)
        XCTAssertEqual(probe.requirementCalls, 1)
    }

    func testConnectionInvalidationForcesStatusRecheckWithoutRequirementLookup() async {
        let probe = SamplingProbe()
        let client = makeClient(probe)
        let first = await client.prepareRefresh()
        XCTAssertTrue(first)
        await client.invalidateConnection(reason: "connectionInvalidated")
        let second = await client.prepareRefresh()
        XCTAssertTrue(second)
        XCTAssertEqual(probe.statusCalls, 2)
        XCTAssertEqual(probe.requirementCalls, 1)
    }

    func testDisabledDaemonReturnsFalseAndRechecksOnEveryCall() async {
        let probe = SamplingProbe()
        probe.setDaemonEnabled(false)
        let client = makeClient(probe)
        for call in 1...3 {
            let ready = await client.prepareRefresh()
            XCTAssertFalse(ready)
            XCTAssertEqual(probe.statusCalls, call)
        }
        XCTAssertEqual(probe.requirementCalls, 0)
        let response = await client.sample(.processMetrics)
        XCTAssertEqual(response.error, HelperSamplingClient.unavailableError)
    }

    func testStatusIsCheckedAgainOnceFiveSecondsHavePassed() async {
        let probe = SamplingProbe()
        let client = makeClient(probe)
        let first = await client.prepareRefresh()
        XCTAssertTrue(first)
        probe.advance(by: 4.5)
        let beforeInterval = await client.prepareRefresh()
        XCTAssertTrue(beforeInterval)
        XCTAssertEqual(probe.statusCalls, 1)
        probe.advance(by: 0.5)
        let afterInterval = await client.prepareRefresh()
        XCTAssertTrue(afterInterval)
        XCTAssertEqual(probe.statusCalls, 2)
    }

    func testFailedRequirementLookupIsNotCached() async {
        let probe = SamplingProbe()
        probe.setRequirement(nil)
        let client = makeClient(probe)
        let failed = await client.prepareRefresh()
        XCTAssertFalse(failed)
        probe.setRequirement("anchor apple generic")
        let recovered = await client.prepareRefresh()
        XCTAssertTrue(recovered)
        let cached = await client.prepareRefresh()
        XCTAssertTrue(cached)
        XCTAssertEqual(probe.requirementCalls, 2)
    }

    func testSampleBeforePrepareRefreshReportsUnavailable() async {
        let probe = SamplingProbe()
        let client = makeClient(probe)
        let response = await client.sample(.powermetrics)
        XCTAssertEqual(response.error, HelperSamplingClient.unavailableError)
        XCTAssertEqual(probe.statusCalls, 0)
    }
}
