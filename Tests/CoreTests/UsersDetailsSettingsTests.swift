import XCTest
@testable import Microgravity

@MainActor
final class UsersDetailsSettingsTests: XCTestCase {
    func testHelperStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.helper(.available), .positive)
        XCTAssertEqual(IntegrationStatusTone.helper(.notConfigured), .neutral)
        XCTAssertEqual(IntegrationStatusTone.helper(.requiresApproval), .attention)
        XCTAssertEqual(IntegrationStatusTone.helper(.unavailable("Not installed")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.helper(.failed("Handshake failed")), .failure)
    }

    func testLoginItemStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.loginItem(.enabled), .positive)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.disabled), .neutral)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.requiresApproval), .attention)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.unavailable("Unsupported")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.loginItem(.failed("Registration failed")), .failure)
    }

    func testUpdateStatusMapsToDotTone() {
        XCTAssertEqual(IntegrationStatusTone.updates(.current), .positive)
        XCTAssertEqual(IntegrationStatusTone.updates(.idle), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.checking), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.updateAvailable(version: "0.2.0")), .attention)
        XCTAssertEqual(IntegrationStatusTone.updates(.unavailable("Not configured")), .neutral)
        XCTAssertEqual(IntegrationStatusTone.updates(.failed("Feed unreachable")), .failure)
    }

    func testProcessesGroupByOwnerUIDInOnePass() {
        let processes = [
            makeProcess(pid: 10, uid: 501),
            makeProcess(pid: 11, uid: 0),
            makeProcess(pid: 12, uid: 501)
        ]

        let grouped = UserAggregation.processesByUID(processes)

        XCTAssertEqual(grouped[501]?.map(\.id.pid), [10, 12])
        XCTAssertEqual(grouped[0]?.map(\.id.pid), [11])
        XCTAssertNil(grouped[502])
    }

    func testCurrentUserMarkerIsKeptOutOfTheName() {
        XCTAssertEqual(UserAggregation.currentUserMarker(isCurrentUser: true), "You")
        XCTAssertEqual(UserAggregation.currentUserMarker(isCurrentUser: false), "")
    }

    func testAppBundlePathUsesOutermostBundleOrNil() {
        XCTAssertEqual(DetailsPresentation.appBundlePath(forExecutable: "/Applications/Safari.app/Contents/MacOS/Safari"),
                       "/Applications/Safari.app")
        XCTAssertEqual(DetailsPresentation.appBundlePath(
            forExecutable: "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                       "/Applications/Chrome.app")
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: "/usr/bin/env"))
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: ""))
        XCTAssertNil(DetailsPresentation.appBundlePath(forExecutable: nil))
    }

    private func makeProcess(pid: Int32, uid: UInt32) -> ProcessSnapshot {
        let timestamp = Date(timeIntervalSince1970: 0)
        let identity = ProcessIdentity(pid: pid,
                                       startTime: ProcessStartTime(secondsSinceEpoch: Int64(pid), microseconds: 0))
        let percent = MetricReading(value: 0, unit: .percent, timestamp: timestamp)
        let bytes = MetricReading(value: 0, unit: .bytes, timestamp: timestamp)
        let rate = MetricReading(value: 0, unit: .bytesPerSecond, timestamp: timestamp)
        return ProcessSnapshot(
            id: identity, parentIdentity: nil, childIdentities: [], name: "process-\(pid)",
            executablePath: nil, ownerUID: uid, isCurrentUser: false, cpuPercent: percent,
            memoryBytes: bytes, diskReadBytesPerSecond: rate, diskWriteBytesPerSecond: rate,
            diskReadTotalBytes: bytes, diskWriteTotalBytes: bytes)
    }
}
