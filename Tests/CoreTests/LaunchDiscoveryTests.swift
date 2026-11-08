import XCTest
import Dispatch
import Darwin
@testable import Microgravity

final class LaunchDiscoveryTests: XCTestCase {
    func testUserLaunchAgentsAreLaunchAgentsNotLoginItems() {
        let specs = LaunchDiscovery.directorySpecs(home: "/Users/example")

        let userAgents = specs.first { $0.path == "/Users/example/Library/LaunchAgents" }
        XCTAssertEqual(userAgents?.kind, .launchAgent)
        XCTAssertEqual(userAgents?.isService, false)
        XCTAssertEqual(specs.first { $0.path == "/Library/StartupItems" }?.kind, .loginItem)
        XCTAssertEqual(specs.filter { $0.isService }.map(\.kind), [.launchDaemon, .launchDaemon])
    }

    func testUserDiscoveryIsCompleteOnNormalScanAndKeepsTheExplanatoryNote() {
        let result = UserDiscovery.collect()

        XCTAssertTrue(result.coverage.complete, "a scan within the record bound must not report incomplete")
        XCTAssertTrue(result.coverage.reasons.contains { $0.contains("utmpx reports terminal login sessions") })
        XCTAssertFalse(result.coverage.reasons.contains { $0.contains("record bound") })
        XCTAssertTrue(result.users.contains { $0.isCurrentUser && $0.uid == getuid() },
                      "the current user is always reported")
    }

    func testPropertyListExtensionIsMatchedCaseInsensitively() {
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.plist"))
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.PLIST"))
        XCTAssertTrue(LaunchDiscovery.isPropertyListName("agent.Plist"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent.plist.bak"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent"))
        XCTAssertFalse(LaunchDiscovery.isPropertyListName("agent.plistx"))
    }

    func testCoverageRemainsCompleteWhenOnlyKnownLimitationsAreRecorded() {
        let coverage = LaunchDiscovery.coverage(
            hadFailure: false,
            reasons: ["Launchd loaded/idle state is not exposed by this read-only plist scan."])

        XCTAssertTrue(coverage.complete)
        XCTAssertEqual(coverage.reasons,
                       ["Launchd loaded/idle state is not exposed by this read-only plist scan."])
    }

    func testCoverageReasonsPutRealFailuresBeforePermanentNotes() {
        let failure = "Could not read /Library/LaunchAgents/broken.plist: The data couldn't be read."
        let reasons = LaunchDiscovery.coverageReasons(
            failures: [failure], missingDirectoryReason: nil, notes: LaunchDiscovery.startupNotes)

        XCTAssertEqual(reasons.first, failure)
        XCTAssertEqual(reasons, [failure,
                                 "Launchd loaded/idle state is not exposed by this read-only plist scan.",
                                 "Background Task Management login items are not available through a public inventory API."])
    }

    func testCoverageReasonsWithoutFailuresAreOnlyTheNotes() {
        XCTAssertEqual(LaunchDiscovery.coverageReasons(failures: [], missingDirectoryReason: nil,
                                                       notes: LaunchDiscovery.serviceNotes),
                       LaunchDiscovery.serviceNotes)
        XCTAssertEqual(LaunchDiscovery.coverageReasons(failures: [], missingDirectoryReason: nil,
                                                       notes: LaunchDiscovery.startupNotes),
                       LaunchDiscovery.startupNotes)
    }

    func testMissingDirectoryReasonSitsBetweenFailuresAndNotes() {
        let reasons = LaunchDiscovery.coverageReasons(
            failures: ["Could not enumerate /Library/LaunchDaemons: Permission denied"],
            missingDirectoryReason: "No service directories were found.",
            notes: LaunchDiscovery.serviceNotes)

        XCTAssertEqual(reasons, ["Could not enumerate /Library/LaunchDaemons: Permission denied",
                                 "No service directories were found.",
                                 "Launchd loaded/idle state is not exposed by this read-only plist scan."])
    }

    func testCoverageIsIncompleteWhenEnumerationOrParsingFailed() {
        let coverage = LaunchDiscovery.coverage(
            hadFailure: true,
            reasons: ["Could not enumerate /Library/LaunchAgents: Permission denied"])

        XCTAssertFalse(coverage.complete)
        XCTAssertEqual(coverage.reasons, ["Could not enumerate /Library/LaunchAgents: Permission denied"])
    }

    func testBoundedReaderReadsRegularFilesAndSmallSymlinksAndRejectsOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let smallData = Data("small plist fixture".utf8)
        let target = directory.appendingPathComponent("target.plist")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: smallData))
        XCTAssertEqual(try LaunchDiscovery.readBoundedRegularFile(at: target.path), smallData)

        let smallSymlink = directory.appendingPathComponent("small-link.plist")
        try FileManager.default.createSymbolicLink(at: smallSymlink, withDestinationURL: target)
        XCTAssertEqual(try LaunchDiscovery.readBoundedRegularFile(at: smallSymlink.path), smallData)

        let boundaryData = Data(repeating: 65, count: LaunchDiscovery.maximumPlistBytes)
        let boundaryFile = directory.appendingPathComponent("boundary.plist")
        XCTAssertTrue(FileManager.default.createFile(atPath: boundaryFile.path, contents: boundaryData))
        XCTAssertEqual(try LaunchDiscovery.readBoundedRegularFile(at: boundaryFile.path).count,
                       LaunchDiscovery.maximumPlistBytes)

        let oversizedData = Data(repeating: 66, count: LaunchDiscovery.maximumPlistBytes + 1)
        let oversizedTarget = directory.appendingPathComponent("oversized-target.plist")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedTarget.path, contents: oversizedData))
        XCTAssertThrowsError(try LaunchDiscovery.readBoundedRegularFile(at: oversizedTarget.path))

        let oversizedSymlink = directory.appendingPathComponent("oversized-link.plist")
        try FileManager.default.createSymbolicLink(at: oversizedSymlink, withDestinationURL: oversizedTarget)
        XCTAssertThrowsError(try LaunchDiscovery.readBoundedRegularFile(at: oversizedSymlink.path))
    }

    func testBoundedReaderRejectsFIFOsAndOtherNonregularFilesWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fifo = directory.appendingPathComponent("fixture.plist")
        let fifoStatus = fifo.path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
        XCTAssertEqual(fifoStatus, 0)
        XCTAssertThrowsError(try LaunchDiscovery.readBoundedRegularFile(at: fifo.path))
        XCTAssertThrowsError(try LaunchDiscovery.readBoundedRegularFile(at: directory.path))
    }

    func testPasswordDatabaseLookupsRemainStableAcrossConcurrentCallers() {
        let uid = UInt32(getuid())
        guard let expectedName = PasswordDatabase.name(for: uid) else {
            XCTFail("the current user account should be present in the password database")
            return
        }

        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let name = PasswordDatabase.name(for: uid)
            let resolvedUID = PasswordDatabase.uid(for: expectedName)
            if name != expectedName || resolvedUID != uid {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(failures, 0)
    }
}
