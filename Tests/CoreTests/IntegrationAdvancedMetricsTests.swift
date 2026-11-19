import XCTest
@testable import Microgravity

final class IntegrationAdvancedMetricsTests: XCTestCase {
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
            .processMetrics: response(.processMetrics, at: start, error: "helperUnavailable"),
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

    func testRetryHelperSoonStartsRefreshInsideBackoffOnlyWhileHelperIsUnavailable() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let gpuOutput = try PropertyListSerialization.data(fromPropertyList: ["gpu": ["idle_ratio": 0.5]], format: .xml, options: 0)
        let client = ToggleHelperClient(clock: clock, gpuOutput: gpuOutput)
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the first refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }

        clock.set(start.addingTimeInterval(5))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        var refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 1, "without a retry request, the 60 s backoff still holds at 5 s")

        // The user approves the helper in System Settings and the app becomes active.
        await client.setInstalled(true)
        await collector.retryHelperSoon()
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2, "a retry request starts a refresh at once, inside the backoff window")
        _ = try await waitForGPUAvailability(true, collector: collector, clock: clock)

        // A healthy helper is not affected by retry requests: the normal cadence still applies.
        clock.set(start.addingTimeInterval(6))
        await collector.retryHelperSoon()
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2, "retry requests are ignored once the last result was not helper-unavailable")
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
        let cap = SystemMonitorCollector.processEnumerationCapDetail
        let stream = StubNettopStream(snapshot: healthyNettopSnapshot(pid: 42, bytesIn: 100, bytesOut: 200, at: clock.now()))
        let collector = NativeAdvancedMetricsCollector(
            client: FixedAdvancedSamplingClient([:]),
            localNettopStream: stream,
            now: { clock.now() },
            processIdentityLookup: { ProcessIdentityLookup(identities: [:], failureDetail: cap) })

        let snapshot = try await waitForNetworkCapability(false, reason: .notCollected,
                                                          collector: collector, at: clock.now())
        XCTAssertEqual(snapshot.capabilities[.processNetwork]?.detail, cap)
        XCTAssertEqual(snapshot.capabilities[.processNetworkReceive]?.detail, cap)
    }

    func testV2FailureDoesNotEmitFakeIdleZerosWhenIdentityLookupIsEmpty() async throws {
        let start = Date(timeIntervalSince1970: 1_800_001_000)
        let stream = StubNettopStream(snapshot: healthyNettopSnapshot(pid: 42, bytesIn: 500, bytesOut: 100, at: start))
        let client = FixedAdvancedSamplingClient([
            .processMetrics: response(.processMetrics, at: start, error: "commandFailed"),
        ])
        let collector = NativeAdvancedMetricsCollector(
            client: client,
            localNettopStream: stream,
            shouldSamplePowermetrics: { false },
            now: { start },
            processIdentityLookup: {
                ProcessIdentityLookup(identities: [:], failureDetail: SystemMonitorCollector.processEnumerationCapDetail)
            }
        )

        _ = await collector.collectAdvancedMetrics(at: start)
        let snapshot = try await waitForNetworkCapability(false, reason: .notCollected,
                                                          collector: collector, at: start)
        XCTAssertNil(snapshot.idleZeroInterval)
        XCTAssertEqual(snapshot.capabilities[.processNetwork]?.detail,
                       SystemMonitorCollector.processEnumerationCapDetail)
    }

    func testNetworkCapabilityBecomesAvailableWhileHelperSampleIsSuspended() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let identity = ProcessIdentity(pid: 42, startTime: .init(secondsSinceEpoch: 100, microseconds: 0))
        let client = HungProcessMetricsClient()
        let stream = StubNettopStream(snapshot: healthyNettopSnapshot(pid: 42, bytesIn: 500, bytesOut: 100, at: start))
        let collector = NativeAdvancedMetricsCollector(client: client, localNettopStream: stream,
                                                       now: { clock.now() },
                                                       processIdentities: { [identity.pid: identity] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the helper sample is suspended") { await client.hasStarted() }
        let snapshot = try await waitForNetworkCapability(true, collector: collector, at: start)
        XCTAssertEqual(snapshot.perProcess[identity]?[.processNetwork]?.value, 600)
        let completed = await collector.refreshCompletionCountForTesting()
        XCTAssertEqual(completed, 0, "the helper refresh is still in flight")

        await client.release()
        try await waitUntil("the released refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }
    }

    func testConnectionFailedDelaysNextHelperRefreshToFiveSeconds() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let client = FixedAdvancedSamplingClient([
            .processMetrics: response(.processMetrics, at: start, error: "connectionFailed"),
            .powermetrics: response(.powermetrics, at: start, error: "unsupported"),
        ])
        let collector = NativeAdvancedMetricsCollector(client: client, now: { clock.now() }, processIdentities: { [:] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the first refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }

        clock.set(start.addingTimeInterval(4))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        var refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 1, "a failed helper call waits five seconds before the next refresh")

        clock.set(start.addingTimeInterval(5))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        refreshCount = await collector.refreshRequestCountForTesting()
        XCTAssertEqual(refreshCount, 2)
    }

    func testGPUAndEnergyWarmUpWhenIOReportMeasuresNatively() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(start)
        let client = ToggleHelperClient(clock: clock, gpuOutput: Data())
        let collector = NativeAdvancedMetricsCollector(client: client, shouldSamplePowermetrics: { false },
                                                       now: { clock.now() }, processIdentities: { [:] })

        _ = await collector.collectAdvancedMetrics(at: start)
        try await waitUntil("the first refresh completes") { await collector.refreshCompletionCountForTesting() == 1 }
        var snapshot = await collector.collectAdvancedMetrics(at: start)
        XCTAssertEqual(snapshot.capabilities[.gpu]?.reason, .warmingUp)
        XCTAssertEqual(snapshot.capabilities[.energy]?.reason, .warmingUp)
        XCTAssertEqual(snapshot.capabilities[.gpu]?.available, false)

        // With the helper present, processMetrics still runs but powermetrics does not, so the reason is unchanged.
        await client.setInstalled(true)
        clock.set(start.addingTimeInterval(60))
        _ = await collector.collectAdvancedMetrics(at: clock.now())
        try await waitUntil("the second refresh completes") { await collector.refreshCompletionCountForTesting() == 2 }
        snapshot = await collector.collectAdvancedMetrics(at: clock.now())
        XCTAssertEqual(snapshot.capabilities[.gpu]?.reason, .warmingUp)
        XCTAssertEqual(snapshot.capabilities[.energy]?.reason, .warmingUp)
        let sampleCount = await client.sampleCount()
        XCTAssertEqual(sampleCount, 1, "only processMetrics is sampled while IOReport measures natively")
    }
}

private func gpuSample(at timestamp: Date) throws -> HelperSampleResponse {
    let data = try PropertyListSerialization.data(fromPropertyList: ["gpu": ["idle_ratio": 0.5]], format: .xml, options: 0)
    return response(.powermetrics, at: timestamp, output: data)
}

private func healthyNettopSnapshot(pid: Int32, bytesIn: UInt64, bytesOut: UInt64, at end: Date) -> NettopStreamSnapshot {
    NettopStreamSnapshot(health: .healthy, capturedAt: end,
                         interval: DateInterval(start: end.addingTimeInterval(-1), end: end),
                         latestSequence: 1,
                         totalsByPID: [pid: NettopDeltaEntry(pid: pid, name: nil, bytesIn: bytesIn, bytesOut: bytesOut)],
                         error: nil)
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

/// processMetrics stays suspended until the test releases it, like a helper that has stopped answering.
private actor HungProcessMetricsClient: AdvancedSamplingClient {
    private var started = false
    private var released = false
    private var resume: CheckedContinuation<Void, Never>?

    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        guard kind == .processMetrics else {
            return response(kind, at: Date(timeIntervalSince1970: 0), error: "unsupported")
        }
        started = true
        if !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                resume = continuation
            }
        }
        return response(kind, at: Date(timeIntervalSince1970: 0), error: "timedOut")
    }

    func hasStarted() -> Bool { started }

    func release() {
        released = true
        resume?.resume()
        resume = nil
    }
}

private struct StubNettopStream: NettopStreamProviding {
    let snapshot: NettopStreamSnapshot

    func latestSnapshot(since sequence: UInt64?, now: Date) -> NettopStreamSnapshot {
        snapshot
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
}
