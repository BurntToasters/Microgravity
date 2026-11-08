import Darwin
import XCTest
@testable import Microgravity

final class LocalProcessActionControllerTests: XCTestCase {
    func testStaleIdentityIsRejectedWithoutSendingSignal() async {
        let requested = identity(pid: 500, second: 1)
        let current = identity(pid: 500, second: 2)
        let signals = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: current, ownerUID: 501, isProtected: false) },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 })

        let result = await controller.terminate(identity: requested, force: false)

        XCTAssertEqual(result.outcome, .rejected(.identityChanged, detail: nil))
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testFinderRelaunchRevalidatesIdentityAndOwnerAndNeverSignals() async {
        let finder = identity(pid: 600, second: 1)
        let signals = SignalRecorder()
        let relaunched = SignalRecorder()
        func controller(_ target: ProcessControlTarget?, failure: String? = nil) -> LocalProcessActionController {
            LocalProcessActionController(
                currentUID: 501, ownPID: 20,
                targetLookup: { _ in target },
                signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 },
                finderRelauncher: { pid in relaunched.append(pid: pid, signal: 0); return failure })
        }

        var result = await controller(.init(identity: finder, ownerUID: 501, isProtected: true))
            .relaunchFinder(identity: finder)
        XCTAssertEqual(result.outcome, .signalSent, "Finder is protected from signals but can be relaunched")

        result = await controller(.init(identity: identity(pid: 600, second: 2), ownerUID: 501, isProtected: true))
            .relaunchFinder(identity: finder)
        XCTAssertEqual(result.outcome, .rejected(.identityChanged, detail: nil))

        result = await controller(.init(identity: finder, ownerUID: 502, isProtected: true))
            .relaunchFinder(identity: finder)
        XCTAssertEqual(result.outcome, .rejected(.differentUser, detail: nil))

        result = await controller(nil).relaunchFinder(identity: finder)
        XCTAssertEqual(result.outcome, .rejected(.processExited, detail: nil))

        result = await controller(.init(identity: finder, ownerUID: 501, isProtected: true), failure: "Finder did not quit.")
            .relaunchFinder(identity: finder)
        XCTAssertEqual(result.outcome, .rejected(.signalFailed, detail: "Finder did not quit."))

        XCTAssertEqual(relaunched.values.count, 2, "only verified Finder identities reach the relauncher")
        XCTAssertTrue(signals.values.isEmpty, "relaunch never sends a signal by PID")
    }

    func testFinderIsRecognizedOnlyAtItsSystemLocationForTheCurrentUser() {
        XCTAssertTrue(FinderProcess.matches(executablePath: FinderProcess.executablePath, ownerUID: 501, currentUID: 501))
        XCTAssertFalse(FinderProcess.matches(executablePath: FinderProcess.executablePath, ownerUID: 502, currentUID: 501))
        XCTAssertFalse(FinderProcess.matches(executablePath: "/Users/me/Finder.app/Contents/MacOS/Finder",
                                             ownerUID: 501, currentUID: 501))
    }

    func testExitedPIDIsReportedWithoutSendingSignal() async {
        let requested = identity(pid: 500, second: 1)
        let signals = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in nil },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 })

        let result = await controller.terminate(identity: requested, force: true)

        XCTAssertEqual(result.outcome, .rejected(.processExited, detail: nil))
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testSelfPidPidOneProtectedAndOtherUserAreRejected() async {
        let signals = SignalRecorder()
        let targets: [Int32: ProcessControlTarget] = [
            20: .init(identity: identity(pid: 20, second: 1), ownerUID: 501, isProtected: false),
            1: .init(identity: identity(pid: 1, second: 1), ownerUID: 0, isProtected: true),
            30: .init(identity: identity(pid: 30, second: 1), ownerUID: 501, isProtected: true),
            40: .init(identity: identity(pid: 40, second: 1), ownerUID: 0, isProtected: false),
        ]
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { targets[$0] },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 })

        let checks: [(Int32, ProcessActionRejection)] = [
            (20, .currentProcess), (1, .pidOne), (30, .protectedProcess), (40, .differentUser),
        ]
        for (pid, expected) in checks {
            let result = await controller.terminate(identity: identity(pid: pid, second: 1), force: false)
            guard case let .rejected(reason, _) = result.outcome else {
                XCTFail("pid \(pid) should be rejected")
                continue
            }
            XCTAssertEqual(reason, expected)
        }
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testOtherUsersLiveProcessIsDifferentUserAndNeverSignaled() async {
        let target = identity(pid: 500, second: 1)
        let signals = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: target, ownerUID: 0, isProtected: false) },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 })

        let result = await controller.terminate(identity: target, force: true)

        XCTAssertEqual(result.outcome, .rejected(.differentUser, detail: nil))
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testSignalEPERMIsReportedAsPermissionDeniedWithItsErrno() async {
        let target = identity(pid: 500, second: 1)
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: target, ownerUID: 501, isProtected: false) },
            signalSender: { _, _ in errno = EPERM; return -1 })

        let result = await controller.terminate(identity: target, force: true)

        XCTAssertEqual(result.outcome, .rejected(.permissionDenied, detail: String(cString: strerror(EPERM))))
    }

    func testSuccessfulActionUsesRequestedSignalAndReturnsOutcome() async {
        let target = identity(pid: 500, second: 1)
        let signals = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: target, ownerUID: 501, isProtected: false) },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 })

        let result = await controller.terminate(identity: target, force: true)

        XCTAssertEqual(result.outcome, .signalSent)
        XCTAssertTrue(result.force)
        XCTAssertEqual(signals.values.map(\.pid), [target.pid])
        XCTAssertEqual(signals.values.map(\.signal), [9])
    }

    func testGracefulApplicationTerminationUsesAppKitAdapter() async {
        let target = identity(pid: 500, second: 1)
        let signals = SignalRecorder()
        let appCalls = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: target, ownerUID: 501, isProtected: false) },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 },
            appTerminator: { pid in appCalls.append(pid: pid, signal: 0); return true })
        let result = await controller.terminate(identity: target, force: false)
        XCTAssertEqual(result.outcome, .signalSent)
        XCTAssertEqual(appCalls.values.map(\.pid), [500])
        XCTAssertTrue(signals.values.isEmpty)
    }

    func testForceDoesNotInvokeAppTermination() async {
        let target = identity(pid: 500, second: 1)
        let signals = SignalRecorder()
        let appCalls = SignalRecorder()
        let controller = LocalProcessActionController(
            currentUID: 501, ownPID: 20,
            targetLookup: { _ in ProcessControlTarget(identity: target, ownerUID: 501, isProtected: false) },
            signalSender: { pid, signal in signals.append(pid: pid, signal: signal); return 0 },
            appTerminator: { pid in appCalls.append(pid: pid, signal: 0); return true })
        let result = await controller.terminate(identity: target, force: true)
        XCTAssertEqual(result.outcome, .signalSent)
        XCTAssertTrue(appCalls.values.isEmpty)
        XCTAssertEqual(signals.values.map(\.signal), [9])
    }

    private func identity(pid: Int32, second: Int64) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: .init(secondsSinceEpoch: 1_800_000_000 + second, microseconds: 0))
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(pid: Int32, signal: Int32)] = []

    func append(pid: Int32, signal: Int32) {
        lock.lock()
        storage.append((pid, signal))
        lock.unlock()
    }

    var values: [(pid: Int32, signal: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
