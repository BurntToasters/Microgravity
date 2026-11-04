import XCTest
@testable import Microgravity

final class IntegrationTerminationPolicyTests: XCTestCase {
    func testRejectsProtectedRootAndChangedIdentity() {
        let requested = HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false)
        XCTAssertTrue(HelperTerminationPolicy.permits(requested, requested: requested, clientPID: 50, helperPID: 60))
        XCTAssertFalse(HelperTerminationPolicy.permits(HelperTarget(pid: 42, seconds: 11, microseconds: 3, owner: 501, protected: false), requested: requested, clientPID: 50, helperPID: 60))
        XCTAssertFalse(HelperTerminationPolicy.permits(HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 0, protected: false), requested: requested, clientPID: 50, helperPID: 60))
        XCTAssertFalse(HelperTerminationPolicy.permits(HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: true), requested: requested, clientPID: 50, helperPID: 60))
        XCTAssertFalse(HelperTerminationPolicy.permits(requested, requested: requested, clientPID: 42, helperPID: 60))
        XCTAssertFalse(HelperTerminationPolicy.permits(requested, requested: requested, clientPID: 50, helperPID: 42))
        let noStart = HelperTarget(pid: 42, seconds: 0, microseconds: 0, owner: 501, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(noStart, requested: noStart, clientPID: 50, helperPID: 60))
        let invalid = HelperTarget(pid: 0, seconds: 10, microseconds: 3, owner: 501, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(invalid, requested: invalid, clientPID: 50, helperPID: 60))
        let launchd = HelperTarget(pid: 1, seconds: 10, microseconds: 3, owner: 501, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(launchd, requested: launchd, clientPID: 50, helperPID: 60))
    }
}
