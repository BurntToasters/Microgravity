import Darwin
import XCTest
@testable import Microgravity

final class HelperProtocolV2Tests: XCTestCase {
    func testProtocolVersionAndWirePayloadsRoundTrip() throws {
        XCTAssertEqual(helperProtocolVersion, 2)
        XCTAssertEqual(Set(HelperSampleKind.allCases), [.powermetrics, .processMetrics])

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for kind in [HelperSampleKind.powermetrics, .processMetrics] {
            let request = HelperSampleRequest(version: helperProtocolVersion, kind: kind)
            let decoded = try decoder.decode(HelperSampleRequest.self, from: encoder.encode(request))
            XCTAssertEqual(decoded.version, 2)
            XCTAssertEqual(decoded.kind, kind)
        }

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

    func testRemovedNettopKindsDoNotDecode() {
        let decoder = JSONDecoder()
        for kind in ["nettop", "nettopStream"] {
            let json = Data("{\"version\":2,\"kind\":\"\(kind)\"}".utf8)
            XCTAssertThrowsError(try decoder.decode(HelperSampleRequest.self, from: json), kind)
        }
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

    func testFailedProcessTableReadKeepsWholeEntriesOnlyAtCap() {
        let entrySize = MemoryLayout<kinfo_proc>.stride
        let cap = HelperProcessMetricsReader.maximumPIDCount
        let bufferBytes = cap * entrySize
        typealias Decision = HelperProcessMetricsReader.FailedTableRead

        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: 2 * entrySize + entrySize / 2, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.truncated(entries: 2), "a partial entry is not kept")
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: bufferBytes, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.truncated(entries: cap))
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: 999_999 * entrySize, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.truncated(entries: cap), "written bytes are clamped to the buffer")
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: 0, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.truncated(entries: cap),
            "a zero length at the cap means the kernel filled the buffer and reported nothing")
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: 0, bufferBytes: entrySize - 1,
            entrySize: entrySize, atCap: true), Decision.retry, "a buffer smaller than one entry keeps nothing")
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: entrySize - 1, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.retry)
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: ENOMEM, bytesReturned: 10 * entrySize, bufferBytes: 100 * entrySize,
            entrySize: entrySize, atCap: false), Decision.retry, "below the cap ENOMEM still re-sizes")
        XCTAssertEqual(HelperProcessMetricsReader.decideFailedTableRead(
            errno: EPERM, bytesReturned: 5 * entrySize, bufferBytes: bufferBytes,
            entrySize: entrySize, atCap: true), Decision.failure, "other errno values remain failures")
    }

    func testDroppingUnwrittenTailKeepsRealEntriesAndOneKernelTaskSlot() {
        func entry(_ pid: Int32) -> kinfo_proc {
            var proc = kinfo_proc()
            proc.kp_proc.p_pid = pid
            return proc
        }
        let pids = { (table: [kinfo_proc]) in table.map { $0.kp_proc.p_pid } }

        XCTAssertEqual(pids(HelperProcessMetricsReader.droppingUnwrittenTail([entry(0), entry(1), entry(0), entry(0)])),
                       [0, 1, 0], "trailing zeros are dropped except one PID-0 slot")
        XCTAssertEqual(pids(HelperProcessMetricsReader.droppingUnwrittenTail([entry(0), entry(1), entry(2)])),
                       [0, 1, 2], "a fully written table is unchanged")
        XCTAssertEqual(pids(HelperProcessMetricsReader.droppingUnwrittenTail([])), [])
    }

    func testTruncatedTableEntriesFailsWhenKernelWroteNoPID() {
        func entry(_ pid: Int32) -> kinfo_proc {
            var proc = kinfo_proc()
            proc.kp_proc.p_pid = pid
            return proc
        }
        let pids = { (table: [kinfo_proc]) in table.map { $0.kp_proc.p_pid } }

        XCTAssertNil(HelperProcessMetricsReader.truncatedTableEntries([kinfo_proc(), kinfo_proc(), kinfo_proc(), kinfo_proc()]),
                     "a zeroed buffer means the kernel wrote nothing, so the read fails")
        XCTAssertEqual(pids(HelperProcessMetricsReader.truncatedTableEntries([kinfo_proc()]) ?? []), [0],
                       "a single slot is kept, because kernel_task is PID 0")
        let partial = [entry(1), entry(2), kinfo_proc(), kinfo_proc()]
        XCTAssertEqual(pids(HelperProcessMetricsReader.truncatedTableEntries(partial) ?? []),
                       pids(HelperProcessMetricsReader.droppingUnwrittenTail(partial)),
                       "a written prefix is trimmed exactly as droppingUnwrittenTail trims it")
    }

    func testProcessTableAtCapOfOneKeepsTheKernelsWholeEntryAndMarksTruncation() throws {
        let capped = try XCTUnwrap(HelperProcessMetricsReader.readProcessTable(maximumCount: 1))
        XCTAssertEqual(capped.entries.count, 1)
        XCTAssertTrue(capped.truncated)

        let full = try XCTUnwrap(HelperProcessMetricsReader.readProcessTable())
        XCTAssertGreaterThan(full.entries.count, 1)
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
