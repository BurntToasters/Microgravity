import Darwin
import XCTest
@testable import Microgravity

final class IntegrationTerminationPolicyTests: XCTestCase {
    func testSharedLookupReportsLaunchdAsRootAndProtected() throws {
        let launchd = try XCTUnwrap(HelperTerminationPolicy.lookupTarget(pid: 1),
                                    "pid 1 must be readable by a non-root process")
        XCTAssertEqual(launchd.pid, 1)
        XCTAssertEqual(launchd.owner, 0)
        XCTAssertTrue(launchd.protected)
        XCTAssertGreaterThan(launchd.seconds, 0)
        XCTAssertNotEqual(launchd.owner, getuid(), "a root process must report another owner to a non-root caller")
    }

    func testSharedLookupReportsOwnProcessAsCurrentUserAndUnprotected() throws {
        let own = try XCTUnwrap(HelperTerminationPolicy.lookupTarget(pid: getpid()))
        XCTAssertEqual(own.pid, getpid())
        XCTAssertEqual(own.owner, getuid())
        XCTAssertFalse(own.protected)
        XCTAssertGreaterThan(own.seconds, 0)
        XCTAssertGreaterThanOrEqual(own.microseconds, 0)
        XCTAssertLessThan(own.microseconds, 1_000_000)
    }

    func testSharedLookupRejectsInvalidAndMissingPIDs() throws {
        XCTAssertNil(HelperTerminationPolicy.lookupTarget(pid: 0))
        XCTAssertNil(HelperTerminationPolicy.lookupTarget(pid: -1))
        // Probe for an unused PID; skip rather than fail if the probe hits a live process.
        let candidate: Int32 = 99_998
        try XCTSkipIf(kill(candidate, 0) == 0 || errno != ESRCH, "PID \(candidate) is in use")
        XCTAssertNil(HelperTerminationPolicy.lookupTarget(pid: candidate))
    }

    func testProtectedPathPolicyIsCentralized() {
        XCTAssertEqual(HelperTerminationPolicy.protectedPathPrefixes,
                       ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/"])
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/sbin/launchd", systemFlag: false))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", systemFlag: false))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/usr/libexec/foo", systemFlag: false))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/usr/sbin/foo", systemFlag: false))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/Applications/App.app/Contents/MacOS/App", systemFlag: true))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: nil, systemFlag: false), "unreadable path is protected")
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "", systemFlag: false), "empty path is protected")
        XCTAssertFalse(HelperTerminationPolicy.isProtected(executablePath: "/Applications/App.app/Contents/MacOS/App", systemFlag: false))
        XCTAssertFalse(HelperTerminationPolicy.isProtected(executablePath: "/usr/local/bin/tool", systemFlag: false))
    }

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

    func testPreflightRejectsExitedReusedRootAndProtectedTargetsBeforeAuthorization() {
        let requested = HelperTargetIdentity(pid: 42, seconds: 10, microseconds: 3)
        XCTAssertEqual(HelperTerminationPolicy.preflightRejection(observed: nil, requested: requested,
                                                                  clientPID: 50), HelperPreflightRejection.processExited)
        XCTAssertEqual(HelperTerminationPolicy.preflightRejection(
            observed: HelperTarget(pid: 42, seconds: 11, microseconds: 3, owner: 501, protected: false),
            requested: requested, clientPID: 50), HelperPreflightRejection.identityChanged)
        XCTAssertEqual(HelperTerminationPolicy.preflightRejection(
            observed: HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 0, protected: false),
            requested: requested, clientPID: 50), HelperPreflightRejection.protectedProcess)
        XCTAssertEqual(HelperTerminationPolicy.preflightRejection(
            observed: HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: true),
            requested: requested, clientPID: 50), HelperPreflightRejection.protectedProcess)
        XCTAssertNil(HelperTerminationPolicy.preflightRejection(
            observed: HelperTarget(pid: 42, seconds: 10, microseconds: 3, owner: 501, protected: false),
            requested: requested, clientPID: 50))
    }
}
