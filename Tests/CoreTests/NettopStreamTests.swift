import XCTest
@testable import Microgravity

private struct StubAdvancedMetricsCollector: AdvancedMetricsCollecting {
    let snapshot: AdvancedMetricsSnapshot

    func collectAdvancedMetrics(at timestamp: Date) async -> AdvancedMetricsSnapshot {
        snapshot
    }
}

final class NettopStreamTests: XCTestCase {
    private var services: [NettopStreamService] = []
    private var abandonedChildren: [SampledChild] = []
    private var markers: [String] = []

    override func tearDown() {
        for service in services { service.stop() }
        services.removeAll()
        for child in abandonedChildren {
            child.kill()
            child.waitForExit()
        }
        abandonedChildren.removeAll()
        for marker in markers { _ = try? runTool("/usr/bin/pkill", ["-9", "-f", marker]) }
        markers.removeAll()
        super.tearDown()
    }

    private func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// True when `pgrep -f` finds a process whose command line contains `marker`.
    private func markerProcessExists(_ marker: String) throws -> Bool {
        let status = try runTool("/usr/bin/pgrep", ["-f", marker])
        switch status {
        case 0: return true
        case 1: return false
        default:
            XCTFail("pgrep exited with status \(status)")
            return true
        }
    }

    private func waitUntilMarkerGone(_ marker: String, within seconds: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if try !markerProcessExists(marker) { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    private func waitForHealthyPID(_ pid: Int32, on service: NettopStreamService, within seconds: TimeInterval) -> NettopStreamSnapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let snapshot = service.latestSnapshot()
            if snapshot.health == .healthy, snapshot.totalsByPID[pid] != nil { return snapshot }
            usleep(100_000)
        } while Date() < deadline
        return nil
    }

    private func fakeNettopCommand(marker: String) -> SamplingRunner.Command {
        let script = "while :; do echo \",bytes_in,bytes_out\"; echo \"proc.4242,10,20\"; sleep 0.3; done # \(marker)"
        return SamplingRunner.Command(executable: "/bin/sh", arguments: ["-c", script])
    }

    func testParserAcceptsScriptTranscriptHeaderAndCarriageReturns() {
        XCTAssertEqual(NettopDeltaFrameParser.sanitized("^D\u{8}\u{8},bytes_in,bytes_out\r"), ",bytes_in,bytes_out")
        XCTAssertEqual(NettopDeltaFrameParser.sanitized("Safari.120,1,2\r"), "Safari.120,1,2")

        let lines = [
            "^D\u{8}\u{8},bytes_in,bytes_out\r",
            "Safari.120,10000,5000\r",
            "Mail.240,250,100\r",
            ",bytes_in,bytes_out\r",
            "Safari.120,1024,512\r",
            ",bytes_in,bytes_out\r",
            "Mail.240,0,4096\r"
        ]
        let t0 = Date(timeIntervalSince1970: 1_800_000_400)
        var parser = NettopDeltaFrameParser()
        var frames: [NettopDeltaFrame] = []
        for (offset, line) in lines.enumerated() {
            if let frame = parser.consumeLine(line, at: t0.addingTimeInterval(Double(offset))) {
                frames.append(frame)
            }
        }
        if let finalFrame = parser.commitPendingFrame(at: t0.addingTimeInterval(Double(lines.count))) {
            frames.append(finalFrame)
        }

        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames[0].isBaseline)
        XCTAssertEqual(frames[0].entries[120]?.bytesIn, 10_000)
        XCTAssertEqual(frames[0].entries[240]?.bytesOut, 100)
        XCTAssertFalse(frames[1].isBaseline)
        XCTAssertEqual(frames[1].entries[120]?.bytesIn, 1_024)
        XCTAssertFalse(frames[2].isBaseline)
        XCTAssertEqual(frames[2].entries[240]?.bytesOut, 4_096)
    }

    func testStopTakesDownChildLaunchedUnderScript() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/script"), "/usr/bin/script is missing")
        let marker = "mg-wp1-stop-\(UUID().uuidString)"
        markers.append(marker)
        let service = NettopStreamService(command: fakeNettopCommand(marker: marker))
        services.append(service)

        let healthy = waitForHealthyPID(4242, on: service, within: 5)
        XCTAssertNotNil(healthy, "stream did not become healthy with pid 4242 within 5 s")
        XCTAssertTrue(try markerProcessExists(marker), "fake nettop was not running")

        service.stop()
        XCTAssertTrue(try waitUntilMarkerGone(marker, within: 2), "child survived stop()")
    }

    func testAbandonedTransportTakesChildDown() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/script"), "/usr/bin/script is missing")
        let marker = "mg-wp1-abandon-\(UUID().uuidString)"
        markers.append(marker)
        let service = NettopStreamService(command: fakeNettopCommand(marker: marker))
        services.append(service)

        XCTAssertNotNil(waitForHealthyPID(4242, on: service, within: 5), "stream did not become healthy within 5 s")

        let abandoned = service.abandonTransportForTesting()
        if let abandoned { abandonedChildren.append(abandoned) }
        XCTAssertNotNil(abandoned)
        XCTAssertTrue(try waitUntilMarkerGone(marker, within: 3), "child survived the read end closing")

        abandoned?.kill()
        abandoned?.waitForExit()
    }

    func testParserSkipsFrame0BaselineAndEmitsSubsequentDeltaFrames() {
        let capture = """
        ,bytes_in,bytes_out,
        Safari.120,10000,5000,
        Mail.240,250,100,
        ,bytes_in,bytes_out,
        Safari.120,1024,512,
        ,bytes_in,bytes_out,
        Mail.240,0,4096,
        """
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(1)
        let t2 = t0.addingTimeInterval(2)

        let frames = NettopDeltaFrameParser.parseFrames(from: capture, frameTimestamps: [t0, t1, t2])
        XCTAssertEqual(frames.count, 3)

        XCTAssertTrue(frames[0].isBaseline)
        XCTAssertNil(frames[0].interval)
        XCTAssertEqual(frames[0].entries[120]?.bytesIn, 10_000)
        XCTAssertEqual(frames[0].entries[240]?.bytesOut, 100)

        XCTAssertFalse(frames[1].isBaseline)
        XCTAssertEqual(frames[1].interval, DateInterval(start: t0, end: t1))
        XCTAssertEqual(frames[1].entries[120]?.bytesIn, 1_024)
        XCTAssertEqual(frames[1].entries[120]?.bytesOut, 512)
        XCTAssertNil(frames[1].entries[240])

        XCTAssertFalse(frames[2].isBaseline)
        XCTAssertEqual(frames[2].interval, DateInterval(start: t1, end: t2))
        XCTAssertEqual(frames[2].entries[240]?.bytesIn, 0)
        XCTAssertEqual(frames[2].entries[240]?.bytesOut, 4_096)
    }

    func testParserHandlesCommasDotsSpacesAndHeaderLines() {
        XCTAssertTrue(NettopDeltaFrameParser.isHeaderLine(",bytes_in,bytes_out,"))
        XCTAssertTrue(NettopDeltaFrameParser.isHeaderLine(" , bytes_in , bytes_out "))
        XCTAssertFalse(NettopDeltaFrameParser.isHeaderLine("Finder.100,0,0,"))

        let parsed = NettopDeltaFrameParser.parseProcessLine("My, App. Helper.42,1024,512,")
        XCTAssertEqual(parsed?.pid, 42)
        XCTAssertEqual(parsed?.name, "My, App. Helper")
        XCTAssertEqual(parsed?.bytesIn, 1_024)
        XCTAssertEqual(parsed?.bytesOut, 512)

        XCTAssertNil(NettopDeltaFrameParser.parseProcessLine("InvalidProcessLine,100,200"))
        XCTAssertNil(NettopDeltaFrameParser.parseProcessLine("ZeroPID.0,100,200"))
    }

    func testParserDropsDuplicatePIDWithinOneFrameAsAmbiguous() {
        let capture = """
        ,bytes_in,bytes_out,
        Helper.99,10,20,
        ,bytes_in,bytes_out,
        Helper.99,100,200,
        Helper.99,300,400,
        Solo.101,50,60,
        """
        let t0 = Date(timeIntervalSince1970: 1_800_000_100)
        let t1 = t0.addingTimeInterval(1)

        let frames = NettopDeltaFrameParser.parseFrames(from: capture, frameTimestamps: [t0, t1])
        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(frames[1].isBaseline)
        XCTAssertNil(frames[1].entries[99], "duplicate PID in the same frame must be discarded")
        XCTAssertEqual(frames[1].entries[101]?.bytesIn, 50)
        XCTAssertEqual(frames[1].entries[101]?.bytesOut, 60)
    }

    func testCollectorFillsAbsentLiveProcessesWithZeroOnlyWhenIdleZeroIntervalIsPresent() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_200)
        let t1 = t0.addingTimeInterval(1)
        let healthyInterval = DateInterval(start: t0, end: t1)

        let healthySnapshot = AdvancedMetricsSnapshot(
            capabilities: [
                .processNetwork: MetricAvailability(available: true),
                .processNetworkReceive: MetricAvailability(available: true),
                .processNetworkTransmit: MetricAvailability(available: true)
            ],
            idleZeroInterval: healthyInterval
        )
        let healthyCollector = SystemMonitorCollector(advancedCollector: StubAdvancedMetricsCollector(snapshot: healthySnapshot))
        let collectedHealthy = await healthyCollector.collect(at: t1)
        let sampleProcess = try XCTUnwrap(collectedHealthy.processes.first { $0.id.pid == getpid() })
        for kind in [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit] {
            let reading = sampleProcess.advancedMetrics[kind]
            XCTAssertEqual(reading?.value, 0)
            XCTAssertEqual(reading?.unit, .bytesPerSecond)
            XCTAssertEqual(reading?.isPartial, false)
            XCTAssertEqual(reading?.measurementInterval, healthyInterval)
        }

        let unavailableSnapshot = AdvancedMetricsSnapshot(
            capabilities: [
                .processNetwork: MetricAvailability(available: false, reason: .notCollected, detail: "warming up"),
                .processNetworkReceive: MetricAvailability(available: false, reason: .notCollected, detail: "warming up"),
                .processNetworkTransmit: MetricAvailability(available: false, reason: .notCollected, detail: "warming up")
            ],
            idleZeroInterval: nil
        )
        let unavailableCollector = SystemMonitorCollector(advancedCollector: StubAdvancedMetricsCollector(snapshot: unavailableSnapshot))
        let collectedUnavailable = await unavailableCollector.collect(at: t1)
        let missingProcess = try XCTUnwrap(collectedUnavailable.processes.first { $0.id.pid == getpid() })
        for kind in [MetricKind.processNetwork, .processNetworkReceive, .processNetworkTransmit] {
            let reading = missingProcess.advancedMetrics[kind]
            XCTAssertNil(reading?.value)
            XCTAssertEqual(reading?.unavailableReason, .notCollected)
        }
    }

    func testParserInitialSequenceStaysMonotonicAcrossRestarts() {
        let capture = """
        ,bytes_in,bytes_out,
        Safari.120,1000,500,
        ,bytes_in,bytes_out,
        Safari.120,256,128,
        """
        var restarted = NettopDeltaFrameParser(initialSequence: 25)
        let t0 = Date(timeIntervalSince1970: 1_800_000_300)
        var frames: [NettopDeltaFrame] = []
        for (offset, rawLine) in capture.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let at = t0.addingTimeInterval(Double(offset))
            if let frame = restarted.consumeLine(String(rawLine), at: at) {
                frames.append(frame)
            }
        }
        if let finalFrame = restarted.commitPendingFrame(at: t0.addingTimeInterval(10)) {
            frames.append(finalFrame)
        }
        XCTAssertEqual(frames.map(\.sequence), [26, 27])
        XCTAssertTrue(frames[0].isBaseline)
        XCTAssertFalse(frames[1].isBaseline)
        XCTAssertEqual(frames[1].entries[120]?.bytesIn, 256)
    }
}
