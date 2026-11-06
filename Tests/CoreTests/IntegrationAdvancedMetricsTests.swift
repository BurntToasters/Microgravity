import XCTest
@testable import Microgravity

final class IntegrationAdvancedMetricsTests: XCTestCase {
    func testFiveSecondCadenceAndTransientNetworkFailurePreserveCounterBaseline() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let identity = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 100, microseconds: 0))
        let client = SerializedAdvancedSamplingClient(clock: clock, responses: [
            .nettop: [
                response(.nettop, at: start, output: Data("time,interface,bytes_in,bytes_out\n0,en0.42,100,200\n".utf8)),
                response(.nettop, at: start.addingTimeInterval(5), error: "temporary failure"),
                response(.nettop, at: start.addingTimeInterval(10), output: Data("time,interface,bytes_in,bytes_out\n0,en0.42,400,700\n".utf8)),
            ],
            .powermetrics: [
                response(.powermetrics, at: start, error: "unsupported"),
                response(.powermetrics, at: start.addingTimeInterval(5), error: "unsupported"),
                response(.powermetrics, at: start.addingTimeInterval(10), error: "unsupported"),
            ],
        ])
        let collector = NativeAdvancedMetricsCollector(
            client: client,
            now: { clock.now() },
            processIdentities: { [identity.pid: identity] })

        _ = await collector.collectAdvancedMetrics(at: start)
        _ = try await waitForNetworkCapability(true, collector: collector, at: start)
        var callCount = await client.callCount()
        var refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(clock.now(), start.addingTimeInterval(1), "both serialized helper samples complete before the tick completes")

        let beforeNextCompletionInterval = start.addingTimeInterval(5)
        clock.set(beforeNextCompletionInterval)
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        callCount = await client.callCount()
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(callCount, 2, "the next tick waits five seconds after completion at t=1")
        XCTAssertEqual(refreshCount, 1, "a start-based cadence would incorrectly schedule at t=5")

        let transientTime = start.addingTimeInterval(6)
        clock.set(transientTime)
        _ = await collector.collectAdvancedMetrics(at: transientTime)
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2, "the completion-based interval expires at t=6")
        _ = try await waitForNetworkCapability(false, reason: .collectionFailed,
                                               collector: collector, at: transientTime)
        callCount = await client.callCount()
        XCTAssertEqual(callCount, 4)
        let sampleStarts = await client.sampleStartTimes()
        guard sampleStarts.count >= 4 else {
            XCTFail("expected two helper samples for each completed refresh")
            return
        }
        XCTAssertEqual(sampleStarts[2], transientTime, "the next refresh starts at t=6")

        let recoveredTime = start.addingTimeInterval(12)
        clock.set(recoveredTime)
        _ = await collector.collectAdvancedMetrics(at: recoveredTime)
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 3)
        let recovered = try await waitForNetworkCapability(true, collector: collector, at: recoveredTime)
        callCount = await client.callCount()
        XCTAssertEqual(callCount, 6)
        let networkCaptures = await client.networkCaptureTimes()
        guard networkCaptures.count == 3 else {
            XCTFail("expected baseline, transient, and recovered nettop captures")
            return
        }
        let elapsed = networkCaptures[2].timeIntervalSince(networkCaptures[0])
        XCTAssertGreaterThan(elapsed, 0)
        XCTAssertEqual(recovered.perProcess[identity]?[.processNetwork]?.value ?? .nan, 800.0 / elapsed,
                       accuracy: 0.0001,
                       "the rate spans the transient miss instead of requiring a new baseline")
        let spacingViolations = await client.spacingViolationCount()
        XCTAssertEqual(spacingViolations, 0, "each helper sample kind must stay at least five seconds apart")
    }

    func testNetworkRejectsDuplicateAndMalformedRowsAndParsesQuotedNames() {
        let csv = "time,interface,bytes_in,bytes_out\n0,\"comma, name.42\",0,12\n0,a.43,20,30\n0,b.43,1,2\n0,broken.44,-1,2\n0,\"open.45,1,2\n"
        let parsed = AdvancedMetricsParser.nettop(csv)
        XCTAssertEqual(parsed[42]?.received, 0)
        XCTAssertEqual(parsed[42]?.sent, 12)
        XCTAssertNil(parsed[43])
        XCTAssertNil(parsed[44])
        XCTAssertNil(parsed[45])
        XCTAssertTrue(AdvancedMetricsParser.nettop("time,interface,bytes_in\n0,x.42,1").isEmpty)
    }

    func testPowerParsesOnlyKnownGPUIdleRatioAcrossNULTerminatedRecords() throws {
        func plist(_ object: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        }
        var data = try plist(["gpu": ["idle_ratio": 0.25]])
        data.append(0)
        data.append(try plist(["gpu": ["idle_ratio": 0.5]]))
        data.append(0)
        XCTAssertEqual(AdvancedMetricsParser.power(data).gpuPercent, 50)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": -0.1]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": 1.1]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(try plist(["gpu": ["idle_ratio": true]])).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)).gpuPercent)
        XCTAssertNil(AdvancedMetricsParser.power(Data("not plist".utf8)).gpuPercent)
    }
    func testEstimatedComponentPowerRequiresAllThreeKnownMilliwattFields() throws {
        func parse(_ fields: [String: Any]) throws -> AdvancedMetricsParser.Power {
            let data = try PropertyListSerialization.data(fromPropertyList: ["processor": fields], format: .xml, options: 0)
            return AdvancedMetricsParser.power(data)
        }
        XCTAssertEqual(try parse(["cpu_power_mw": 1000, "gpu_power_mw": 2500, "ane_power_mw": 500]).watts, 4)
        XCTAssertNil(try parse(["cpu_power_mw": 1000, "gpu_power_mw": 0]).watts)
        XCTAssertNil(try parse(["cpu_power_mw": -1, "gpu_power_mw": 0, "ane_power_mw": 0]).watts)
        XCTAssertNil(try parse(["cpu_power_mw": true, "gpu_power_mw": 0, "ane_power_mw": 0]).watts)
    }

    func testProcessGPURequiresExplicitTimeUnitsAndRejectsDuplicates() throws {
        let tasks: [[String: Any]] = [
            ["pid": 42, "gpu_time_ms": 1250], ["pid": 43, "gpu_time_ns": 500_000_000],
            ["pid": 44, "gpu_time": 99], ["pid": 45, "gpu_time_ms": -1],
            ["pid": 46, "gpu_time_ms": 2], ["pid": 46, "gpu_time_ms": 3]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["tasks": tasks], format: .xml, options: 0)
        let parsed = AdvancedMetricsParser.power(data)
        XCTAssertEqual(parsed.processGPUSeconds[42], 1.25)
        XCTAssertEqual(parsed.processGPUSeconds[43], 0.5)
        XCTAssertNil(parsed.processGPUSeconds[44])
        XCTAssertNil(parsed.processGPUSeconds[45])
        XCTAssertNil(parsed.processGPUSeconds[46])
    }

    func testNetworkRatesRequireStableIdentityAndRejectReset() {
        let old = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 100, microseconds: 0))
        let replacement = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 200, microseconds: 0))
        let t = Date(timeIntervalSince1970: 1_000)
        var accumulator = AdvancedNetworkAccumulator()
        let first = accumulator.update([42: .init(received: 100, sent: 200)], before: [42: old], after: [42: old], at: t)
        XCTAssertEqual(first[old]?[.processNetwork]?.unavailableReason, .warmingUp)
        let second = accumulator.update([42: .init(received: 150, sent: 300)], before: [42: old], after: [42: old], at: t.addingTimeInterval(5))
        XCTAssertEqual(second[old]?[.processNetwork]?.value, 30)
        let reused = accumulator.update([42: .init(received: 200, sent: 400)], before: [42: old], after: [42: replacement], at: t.addingTimeInterval(10))
        XCTAssertTrue(reused.isEmpty)
        let new = accumulator.update([42: .init(received: 2, sent: 3)], before: [42: replacement], after: [42: replacement], at: t.addingTimeInterval(15))
        XCTAssertEqual(new[replacement]?[.processNetwork]?.unavailableReason, .warmingUp)
        let reset = accumulator.update([42: .init(received: 1, sent: 1)], before: [42: replacement], after: [42: replacement], at: t.addingTimeInterval(20))
        XCTAssertEqual(reset[replacement]?[.processNetwork]?.unavailableReason, .counterReset)
    }

}

private func response(_ kind: HelperSampleKind, at timestamp: Date,
                      output: Data? = nil, error: String? = nil) -> HelperSampleResponse {
    HelperSampleResponse(version: helperProtocolVersion, kind: kind, capturedAt: timestamp,
                         output: output, error: error)
}

private func waitForNetworkCapability(_ available: Bool, reason: MetricUnavailableReason? = nil,
                                      collector: NativeAdvancedMetricsCollector,
                                      at timestamp: Date) async throws -> AdvancedMetricsSnapshot {
    for _ in 0..<200 {
        let snapshot = await collector.collectAdvancedMetrics(at: timestamp)
        if let capability = snapshot.capabilities[.processNetwork],
           capability.available == available,
           reason == nil || capability.reason == reason {
            return snapshot
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("advanced network sample did not reach the expected capability state")
    throw NSError(domain: "IntegrationAdvancedMetricsTests", code: 1)
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

private actor SerializedAdvancedSamplingClient: AdvancedSamplingClient {
    private let clock: TestClock
    private var responses: [HelperSampleKind: [HelperSampleResponse]]
    private var offsets: [HelperSampleKind: Int] = [:]
    private var calls = 0
    private var lastStartedAt: [HelperSampleKind: Date] = [:]
    private var spacingViolations = 0
    private var nettopCaptureTimes: [Date] = []
    private var sampleStarts: [Date] = []

    init(clock: TestClock, responses: [HelperSampleKind: [HelperSampleResponse]]) {
        self.clock = clock
        self.responses = responses
    }

    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        calls += 1
        let startedAt = clock.now()
        sampleStarts.append(startedAt)
        let violatesSpacing = lastStartedAt[kind].map { startedAt.timeIntervalSince($0) < 5 } ?? false
        if violatesSpacing { spacingViolations += 1 }
        lastStartedAt[kind] = startedAt
        let index = offsets[kind, default: 0]
        offsets[kind] = index + 1
        let entries = responses[kind] ?? []
        let queued = entries.indices.contains(index) ? entries[index] : response(kind, at: startedAt, error: "no queued response")
        if kind == .nettop { nettopCaptureTimes.append(startedAt) }
        // Advancing the virtual clock models serialized helper work completing.
        clock.advance(by: 0.5)
        if violatesSpacing {
            return response(kind, at: startedAt, error: "rateLimited")
        }
        return response(kind, at: startedAt, output: queued.output, error: queued.error)
    }

    func callCount() -> Int { calls }
    func spacingViolationCount() -> Int { spacingViolations }
    func networkCaptureTimes() -> [Date] { nettopCaptureTimes }
    func sampleStartTimes() -> [Date] { sampleStarts }
}
