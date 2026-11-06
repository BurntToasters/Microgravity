import XCTest
import Dispatch
import Darwin
@testable import Microgravity

final class LaunchDiscoveryTests: XCTestCase {
    func testPropertyListExtensionIsMatchedCaseInsensitively() {
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.plist"))
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.PLIST"))
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.Plist"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent.plist.bak"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent.plistx"))
    }

    func testCoverageRemainsCompleteWhenOnlyKnownLimitationsAreRecorded() {
        let coverage = LaunchDiscovery.coverage(
            hadFailure: false,
            reasons: ["Launchd loaded/idle state is not exposed by this read-only plist scan."])

        XCTAssertTrue(coverage.complete)
        XCTAssertEqual(coverage.reasons,
                       ["Launchd loaded/idle state is not exposed by this read-only plist scan."])
    }

    func testCoverageIsIncompleteWhenEnumerationOrParsingFailed() {
        let coverage = LaunchDiscovery.coverage(
            hadFailure: true,
            reasons: ["Could not enumerate /Library/LaunchAgents: Permission denied"])

        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.reasons, ["Could not enumerate /Library/LaunchAgents: Permission denied"])
    }

    func testPasswordDatabaseLookupsRemainStableAcrossConcurrentCallers() {
        let uid = UInt32(getuid())
        guard let expectedName = PasswordDatabase.name(for: uid) else {
            XCTFail("the current user account should be present in the password database")
            return
        }

        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let name = PasswordDatabase.name(for: uid)
            let resolvedUID = PasswordDatabase.uid(for: expectedName)
            if name != expectedName || resolvedUID != uid {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(failures, 0)
    }
}
