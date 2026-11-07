import XCTest
@testable import Microgravity

final class IntegrationXPCReplyTests: XCTestCase {
    func testFirstFinisherWinsAndLaterFinishersAreNoOps() async {
        let connection = NSXPCConnection(machServiceName: "run.rosie.microgravity.tests.unused")
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let reply = XPCSingleReply(continuation, connection: connection, timeout: 0.01,
                                       timeoutValue: "timed out")
            reply.finish("reply")
            reply.finish("late reply")
            reply.armTimeout()
        }
        XCTAssertEqual(value, "reply")
    }

    func testTimeoutResumesAHungRequestWithItsValue() async {
        let connection = NSXPCConnection(machServiceName: "run.rosie.microgravity.tests.unused")
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let reply = XPCSingleReply(continuation, connection: connection, timeout: 0.01,
                                       timeoutValue: "timed out")
            reply.armTimeout()
        }
        XCTAssertEqual(value, "timed out")
    }
}
