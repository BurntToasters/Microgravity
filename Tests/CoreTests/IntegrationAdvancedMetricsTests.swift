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
    func testPerProcessGPUTimeIsUnsupportedAndNeverEmitted() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let identity = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 100, microseconds: 0))
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["gpu": ["idle_ratio": 0.5], "tasks": [["pid": 42, "gpu_time_ms": 1250]]],
            format: .xml, options: 0)
        let client = FixedAdvancedSamplingClient([.powermetrics: response(.powermetrics, at: clock.now(), output: data)])
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() },
                                                       processIdentities: { [identity.pid: identity] })

        _ = await collector.collectAdvancedMetrics(at: clock.now())
        let snapshot = try await waitForGPUAvailability(true, collector: collector, clock: clock)
        XCTAssertEqual(snapshot.capabilities[.processGPUTime],
                       MetricAvailability(available: false, reason: .unsupported,
                                          detail: "Per-process GPU time is not collected."))
        XCTAssertTrue(snapshot.perProcess.values.allSatisfy { $0[.processGPUTime] == nil })
    }

    func testHelperAbsenceBacksOffToSixtySecondsAndRecoversToFiveSecondCadence() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let gpuOutput = try PropertyListSerialization.data(fromPropertyList: ["gpu": ["idle_ratio": 0.5]], format: .xml, options: 0)
        let client = ToggleHelperClient(clock: clock, gpuOutput: gpuOutput)
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the first refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }
        var snapshot = await collector.collectAdvancedMetrics(at: start)
        XCTAssertEqual(snapshot.capabilities[.gpu]?.detail, NativeAdvancedMetricsCollector.helperRequiredDetail)
        var refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 1)
        var sampleCount = await client.sampleCount()
        XCTAssertEqual(sampleCount, 0, "no helper samples are requested while the helper is absent")

        for offset in [TimeInterval(5), 30, 59] {
            clock.set(start.addingTimeInterval(offset))
            snapshot = await collector.collectAdvancedMetrics(at: clock.now())
            XCTAssertEqual(snapshot.capabilities[.gpu]?.detail, NativeAdvancedMetricsCollector.helperRequiredDetail,
                           "the cached helper reason stays accurate past 30 s")
        }
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 1, "no refresh is requested before 60 s")

        clock.set(start.addingTimeInterval(60))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2)
        try await waitUntil("the second refresh completes") { await collector.refreshCompletionCountForTesting() == 2 }
        // The refresh's prepare call has read the helper state before this point, so the helper can appear now.
        await client.setInstalled(true)

        clock.set(start.addingTimeInterval(65))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2, "still inside the 60 s retry interval")

        clock.set(start.addingTimeInterval(120))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 3)
        _ = try await waitForGPUAvailability(true, collector: collector, clock: clock)

        clock.set(start.addingTimeInterval(125))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 4, "a successful sample restores the five-second cadence")
        try await waitUntil("the fourth refresh completes") { await collector.refreshCompletionCountForTesting() == 4 }

        let prepareCount = await client.prepareCount()
        XCTAssertEqual(prepareCount, 4, "helper registration is checked once per refresh")
        sampleCount = await client.sampleCount()
        XCTAssertEqual(sampleCount, 4, "the two recovered refreshes sampled both kinds")
    }

    func testHelperUnavailableSampleResponseAlsoBacksOffToSixtySeconds() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let client = FixedAdvancedSamplingClient([
            .nettop: response(.nettop, at: start, error: "helperUnavailable"),
            .powermetrics: response(.powermetrics, at: start, error: "helperUnavailable"),
        ])
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the first refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }
        clock.set(start.addingTimeInterval(59))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        var refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 1, "no new refresh until 60 s after a helperUnavailable response")

        clock.set(start.addingTimeInterval(60))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2)
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

    func testCachedSystemReadingOlderThanThirtySecondsIsDroppedAtReadTime() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let captured = Date(timeIntervalSince1970: 980)
        let client = FixedAdvancedSamplingClient([.powermetrics: try gpuSample(at: captured)])
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        let fresh = try await waitForGPUAvailability(true, collector: collector, clock: clock)
        XCTAssertEqual(fresh.system[.gpu]?.value, 50)

        clock.set(Date(timeIntervalSince1970: 1_011))
        let stale = await collector.collectAdvancedMetrics(at: clock.now())
        XCTAssertNil(stale.system[.gpu], "a 31s-old GPU reading must not be served from the cache")
        XCTAssertEqual(stale.capabilities[.gpu]?.available, false)
        XCTAssertEqual(stale.capabilities[.gpu]?.reason, .collectionFailed)
    }

    func testFreshSystemReadingStillPassesThroughAtReadTime() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let captured = Date(timeIntervalSince1970: 1_000)
        let client = FixedAdvancedSamplingClient([.powermetrics: try gpuSample(at: captured)])
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        _ = try await waitForGPUAvailability(true, collector: collector, clock: clock)

        clock.set(Date(timeIntervalSince1970: 1_020))
        let snapshot = await collector.collectAdvancedMetrics(at: clock.now())
        XCTAssertEqual(snapshot.capabilities[.gpu]?.available, true)
        XCTAssertEqual(snapshot.system[.gpu]?.value, 50)
        XCTAssertEqual(snapshot.system[.gpu]?.timestamp, captured)
    }

    func testIdentityEnumerationCapIsNamedInNetworkCapabilityDetail() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let cap = "Process list is 5242881 bytes, above the 4 MiB identity cap"
        let client = FixedAdvancedSamplingClient([
            .nettop: response(.nettop, at: clock.now(),
                              output: Data("time,interface,bytes_in,bytes_out\n0,en0.42,100,200\n".utf8)),
            .powermetrics: response(.powermetrics, at: clock.now(), error: "unsupported"),
        ])
        let collector = NativeAdvancedMetricsCollector(
            client: client, now: { clock.now() },
            processIdentityLookup: { ProcessIdentityLookup(identities: [:], failureDetail: cap) })

        _ = await collector.collectAdvancedMetrics(at: clock.now())
        let snapshot = try await waitForNetworkCapability(false, reason: .notCollected,
                                                          collector: collector, at: clock.now())
        XCTAssertEqual(snapshot.capabilities[.processNetwork]?.detail, cap)
        XCTAssertEqual(snapshot.capabilities[.processNetworkReceive]?.detail, cap)
    }

}

private func gpuSample(at timestamp: Date) throws -> HelperSampleResponse {
    let data = try PropertyListSerialization.data(fromPropertyList: ["gpu": ["idle_ratio": 0.5]], format: .xml, options: 0)
    return response(.powermetrics, at: timestamp, output: data)
}

private func waitUntil(_ description: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting until \(description)")
    throw NSError(domain: "IntegrationAdvancedMetricsTests", code: 3)
}

private func waitForGPUAvailability(_ available: Bool, collector: NativeAdvancedMetricsCollector,
                                    clock: TestClock) async throws -> AdvancedMetricsSnapshot {
    for _ in 0..<200 {
        let snapshot = await collector.collectAdvancedMetrics(at: clock.now())
        if snapshot.capabilities[.gpu]?.available == available { return snapshot }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("GPU sample did not reach the expected capability state")
    throw NSError(domain: "IntegrationAdvancedMetricsTests", code: 2)
}

/// Helper presence is toggled by the test; samples succeed for powermetrics only once it is installed.
private actor ToggleHelperClient: AdvancedSamplingClient {
    private let clock: TestClock
    private let gpuOutput: Data
    private var installed = false
    private var prepares = 0
    private var samples = 0

    init(clock: TestClock, gpuOutput: Data) {
        self.clock = clock
        self.gpuOutput = gpuOutput
    }

    func setInstalled(_ value: Bool) { installed = value }
    func prepareCount() -> Int { prepares }
    func sampleCount() -> Int { samples }

    func prepareRefresh() async -> Bool {
        prepares += 1
        return installed
    }

    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        samples += 1
        let at = clock.now()
        guard installed else { return response(kind, at: at, error: "helperUnavailable") }
        return kind == .powermetrics ? response(kind, at: at, output: gpuOutput) : response(kind, at: at, error: "unsupported")
    }
}

private actor FixedAdvancedSamplingClient: AdvancedSamplingClient {
    private let responses: [HelperSampleKind: HelperSampleResponse]

    init(_ responses: [HelperSampleKind: HelperSampleResponse]) { self.responses = responses }

    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        responses[kind] ?? response(kind, at: Date(timeIntervalSince1970: 0), error: "no queued response")
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
