import Darwin
import XCTest
@testable import Microgravity

final class HelperProtocolV2Tests: XCTestCase {
    func testProtocolVersionAndWirePayloadsRoundTrip() throws {
        XCTAssertEqual(helperProtocolVersion, 2)

        let streamRequest = HelperSampleRequest(version: helperProtocolVersion, kind: .nettopStream, sinceSequence: 42)
        let metricsRequest = HelperSampleRequest(version: helperProtocolVersion, kind: .processMetrics)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let decodedStreamRequest = try decoder.decode(HelperSampleRequest.self, from: encoder.encode(streamRequest))
        XCTAssertEqual(decodedStreamRequest.version, 2)
        XCTAssertEqual(decodedStreamRequest.kind, .nettopStream)
        XCTAssertEqual(decodedStreamRequest.sinceSequence, 42)

        let decodedMetricsRequest = try decoder.decode(HelperSampleRequest.self, from: encoder.encode(metricsRequest))
        XCTAssertEqual(decodedMetricsRequest.version, 2)
        XCTAssertEqual(decodedMetricsRequest.kind, .processMetrics)
        XCTAssertNil(decodedMetricsRequest.sinceSequence)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(1)
        let streamPayload = HelperNettopStreamPayload(
            health: .healthy,
            intervalStart: start,
            intervalEnd: end,
            sequence: 7,
            entries: [HelperNettopDeltaEntry(pid: 123, bytesIn: 2_048, bytesOut: 1_024)],
            detail: nil
        )
        let decodedStreamPayload = try decoder.decode(HelperNettopStreamPayload.self, from: encoder.encode(streamPayload))
        XCTAssertEqual(decodedStreamPayload, streamPayload)

        let metricsPayload = HelperProcessMetricsPayload(entries: [
            HelperProcessMetricEntry(
                pid: 123, startSeconds: 1_700_000_000, startMicroseconds: 500,
                cpuTotalNanoseconds: 9_000_000, memoryBytes: 65_536,
                diskReadBytes: 4_096, diskWriteBytes: 2_048,
                threadCount: 4, executablePath: "/Applications/Test.app/Contents/MacOS/Test"
            )
        ])
        let decodedMetricsPayload = try decoder.decode(HelperProcessMetricsPayload.self, from: encoder.encode(metricsPayload))
        XCTAssertEqual(decodedMetricsPayload, metricsPayload)
    }

    func testHelperProcessMetricsReaderReadsCurrentProcessSafely() throws {
        let payload = HelperProcessMetricsReader.collect(excludingUID: nil)
        let selfEntry = try XCTUnwrap(payload.entries.first { $0.pid == getpid() })
        XCTAssertGreaterThan(selfEntry.startSeconds, 0)
        XCTAssertTrue((0..<1_000_000).contains(selfEntry.startMicroseconds))
        XCTAssertNotNil(selfEntry.cpuTotalNanoseconds)
        XCTAssertNotNil(selfEntry.memoryBytes)
        XCTAssertGreaterThan(selfEntry.threadCount ?? 0, 0)
        XCTAssertNotNil(selfEntry.executablePath)
    }

    func testHelperTerminationPolicyPreservesProtectionInvariants() {
        let validStartSeconds: Int64 = 1_700_000_000
        let selfPID = getpid()

        let pidOne = HelperTarget(pid: 1, seconds: validStartSeconds, microseconds: 0, owner: 501, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(pidOne, requested: pidOne, clientPID: selfPID, helperPID: 999))

        let current = HelperTarget(pid: selfPID, seconds: validStartSeconds, microseconds: 0, owner: 501, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(current, requested: current, clientPID: selfPID, helperPID: 999))

        let rootOwned = HelperTarget(pid: 450, seconds: validStartSeconds, microseconds: 0, owner: 0, protected: false)
        XCTAssertFalse(HelperTerminationPolicy.permits(rootOwned, requested: rootOwned, clientPID: selfPID, helperPID: 999))

        for path in [
            "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            "/usr/libexec/logd",
            "/usr/sbin/sshd",
            "/sbin/launchd"
        ] {
            XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: path, systemFlag: false), path)
        }
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: nil, systemFlag: false))
        XCTAssertTrue(HelperTerminationPolicy.isProtected(executablePath: "/Applications/UserApp.app/Contents/MacOS/UserApp", systemFlag: true))
    }
}
