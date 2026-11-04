import XCTest
@testable import Microgravity

final class IntegrationRunnerTests: XCTestCase {
    private func run(_ runner: SamplingRunner, _ token: SamplingCancellation = SamplingCancellation()) async -> HelperSampleResponse {
        await withCheckedContinuation { continuation in
            runner.sample(HelperSampleRequest(version: helperProtocolVersion, kind: .nettop), cancellation: token) { continuation.resume(returning: $0) }
        }
    }
    func testFixedCommandsHaveNoShellOrCallerArguments() {
        let net = SamplingRunner.fixedCommand(.nettop)
        let power = SamplingRunner.fixedCommand(.powermetrics)
        XCTAssertEqual(net.executable, "/usr/bin/nettop")
        XCTAssertEqual(power.executable, "/usr/bin/powermetrics")
        XCTAssertFalse(net.arguments.contains("-c"))
        XCTAssertFalse(power.arguments.contains("-c"))
    }
    func testRateLimitAndBoundedOutput() async {
        let runner = SamplingRunner(command: { _ in .init(executable: "/usr/bin/yes", arguments: []) }, outputLimit: 1024)
        let first = await run(runner)
        XCTAssertEqual(first.error, "outputLimit")
        XCTAssertNil(first.output)
        let second = await run(runner)
        XCTAssertEqual(second.error, "rateLimited")
    }
    func testInvalidVersionAndPreCancelledRequestDoNotLaunch() async {
        let runner = SamplingRunner(command: { _ in .init(executable: "/bin/sleep", arguments: ["10"]) })
        let invalid: HelperSampleResponse = await withCheckedContinuation { continuation in
            runner.sample(HelperSampleRequest(version: 99, kind: .nettop), cancellation: SamplingCancellation()) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(invalid.error, "incompatibleVersion")
        let token = SamplingCancellation()
        token.cancel()
        let cancelled = await run(runner, token)
        XCTAssertEqual(cancelled.error, "disconnected")
    }
    func testBurstIsBoundedAndCancellingPendingReleasesCapacity() async {
        let runner = SamplingRunner(command: { _ in .init(executable: "/bin/sleep", arguments: ["10"]) }, timeoutNanoseconds: 2_000_000_000, intervalNanoseconds: 0)
        let first = SamplingCancellation(), second = SamplingCancellation(), third = SamplingCancellation()
        let active = Task { await run(runner, first) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let pending1 = Task { await run(runner, second) }
        let pending2 = Task { await run(runner, third) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let rejected = await run(runner)
        XCTAssertEqual(rejected.error, "busy")
        second.cancel()
        let cancelled = await pending1.value
        XCTAssertEqual(cancelled.error, "disconnected")
        let fourthToken = SamplingCancellation()
        let replacement = Task { await run(runner, fourthToken) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let stillFull = await run(runner)
        XCTAssertEqual(stillFull.error, "busy")
        first.cancel(); third.cancel(); fourthToken.cancel()
        _ = await active.value; _ = await pending2.value; _ = await replacement.value
    }
    func testTimeoutAndCancellationStopChild() async {
        let runner = SamplingRunner(command: { _ in .init(executable: "/bin/sleep", arguments: ["10"]) }, timeoutNanoseconds: 100_000_000, intervalNanoseconds: 0)
        let result = await run(runner)
        XCTAssertEqual(result.error, "timedOut")
        let token = SamplingCancellation()
        let task = Task { await run(runner, token) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        token.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.error, "disconnected")
    }
}
