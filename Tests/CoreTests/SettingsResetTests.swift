import AppKit
import XCTest
@testable import Microgravity

/// Records relaunch requests instead of starting a process. Never launches anything.
@MainActor
private final class RecordingRelauncher: SettingsRelauncher {
    private(set) var requests: [SettingsRelaunchRequest] = []
    var failure: Error?

    func relaunch(_ request: SettingsRelaunchRequest) throws {
        requests.append(request)
        if let failure { throw failure }
    }
}

@MainActor
private final class CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct StubRelaunchFailure: Error {}

private let fakeBundleURL = URL(fileURLWithPath: "/Applications/Microgravity.app")
private let fakeProcessID: Int32 = 4242

private func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == identifier { return root }
    for subview in root.subviews {
        if let found = view(withIdentifier: identifier, in: subview) { return found }
    }
    return nil
}

@MainActor
final class SettingsResetTests: XCTestCase {
    /// An isolated suite that stands in for the app's defaults domain. Removed on `tearDown`.
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsResetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func seedSettings() {
        defaults.set(["cpu": "#FF0000"], forKey: ColorPreferences.defaultsKey)
        defaults.set(2.0, forKey: SamplingControls.refreshIntervalDefaultsKey)
        defaults.set("flat", forKey: "process.grouping")
        defaults.set("dark", forKey: "monitoring.appearance")
        defaults.set("#00FF00", forKey: "appearance.accent")
        defaults.set("1 2 3 4", forKey: "NSWindow Frame Main")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set(Data([1, 2, 3]), forKey: "NSTableView Columns v3 process.outline")
    }

    private func makeService(relauncher: any SettingsRelauncher,
                             terminations: CallCounter? = nil,
                             bundleURL: URL = fakeBundleURL,
                             processID: Int32 = fakeProcessID) -> SettingsResetService {
        let counter = terminations ?? CallCounter()
        return SettingsResetService(defaults: defaults, domainName: suiteName, bundleURL: bundleURL,
                                    processID: processID, relauncher: relauncher,
                                    terminate: { counter.increment() })
    }

    // MARK: Settings page

    func testSettingsPageHasResetAllButtonInItsOwnCard() throws {
        let configuration = FixtureConfiguration(arguments: [])
        let settings = SettingsViewController(dependencies: PageDependencies(
            monitoringStore: FixtureMonitoringStore(configuration: configuration),
            processActions: FixtureProcessActioner(configuration: configuration),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: true
        ))
        settings.loadViewIfNeeded()

        let button = try XCTUnwrap(view(withIdentifier: "settings.reset-all", in: settings.view) as? NSButton)
        XCTAssertEqual(button.title, "Reset All Settings…")
        XCTAssertTrue(button.isEnabled)
        XCTAssertNotNil(view(withIdentifier: "settings.version", in: settings.view))
    }

    // MARK: Reset

    func testResetClearsEveryKeyInTheDomainAndRelaunchesExactlyOnce() throws {
        seedSettings()
        let relauncher = RecordingRelauncher()
        let terminations = CallCounter()
        let service = makeService(relauncher: relauncher, terminations: terminations)

        try service.apply(.resetAndRestart)

        for key in [ColorPreferences.defaultsKey, SamplingControls.refreshIntervalDefaultsKey, "process.grouping",
                    "monitoring.appearance", "appearance.accent", "NSWindow Frame Main", "SUEnableAutomaticChecks",
                    "NSTableView Columns v3 process.outline"] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be reset")
        }
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        XCTAssertEqual(relauncher.requests.count, 1)
        XCTAssertEqual(terminations.count, 1)
        XCTAssertTrue(service.isClearPending)
    }

    func testCancelChangesNothingAndCallsNothing() throws {
        seedSettings()
        let relauncher = RecordingRelauncher()
        let terminations = CallCounter()
        let service = makeService(relauncher: relauncher, terminations: terminations)

        try service.apply(SettingsResetDecision(response: .alertSecondButtonReturn))

        XCTAssertEqual(SettingsResetDecision(response: .alertSecondButtonReturn), .cancel)
        XCTAssertEqual(SettingsResetDecision(response: .alertFirstButtonReturn), .resetAndRestart)
        XCTAssertEqual(defaults.double(forKey: SamplingControls.refreshIntervalDefaultsKey), 2.0)
        XCTAssertEqual(defaults.string(forKey: "process.grouping"), "flat")
        XCTAssertNotNil(defaults.object(forKey: ColorPreferences.defaultsKey))
        XCTAssertTrue(relauncher.requests.isEmpty)
        XCTAssertEqual(terminations.count, 0)
        XCTAssertFalse(service.isClearPending)
    }

    func testClearAtQuitRemovesValuesWrittenAfterTheReset() throws {
        let relauncher = RecordingRelauncher()
        let service = makeService(relauncher: relauncher)
        try service.apply(.resetAndRestart)

        // A window writes its frame back after the reset but before the process exits.
        defaults.set("0 0 900 600 0 0 1440 875 ", forKey: "NSWindow Frame Main")
        service.clearAtQuitIfPending()

        XCTAssertNil(defaults.object(forKey: "NSWindow Frame Main"))
    }

    func testClearAtQuitDoesNothingWithoutAPendingReset() {
        let service = makeService(relauncher: RecordingRelauncher())
        defaults.set("1 2 3 4", forKey: "NSWindow Frame Main")

        service.clearAtQuitIfPending()

        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame Main"), "1 2 3 4")
    }

    func testRelaunchFailureClearsSettingsButKeepsTheAppOpen() throws {
        seedSettings()
        let relauncher = RecordingRelauncher()
        relauncher.failure = StubRelaunchFailure()
        let terminations = CallCounter()
        let service = makeService(relauncher: relauncher, terminations: terminations)

        XCTAssertThrowsError(try service.apply(.resetAndRestart)) { error in
            XCTAssertEqual(error as? SettingsResetError, .restartFailed)
        }

        XCTAssertNil(defaults.object(forKey: ColorPreferences.defaultsKey))
        XCTAssertEqual(relauncher.requests.count, 1)
        XCTAssertEqual(terminations.count, 0, "The app must not quit when the restart was not set up")
    }

    func testInvalidRelaunchSetupFailsBeforeAnythingIsCleared() throws {
        seedSettings()
        let relauncher = RecordingRelauncher()
        let terminations = CallCounter()
        let service = makeService(relauncher: relauncher, terminations: terminations, processID: 0)

        XCTAssertThrowsError(try service.apply(.resetAndRestart)) { error in
            XCTAssertEqual(error as? SettingsResetError, .restartUnavailable)
        }

        XCTAssertEqual(defaults.double(forKey: SamplingControls.refreshIntervalDefaultsKey), 2.0)
        XCTAssertNotNil(defaults.object(forKey: ColorPreferences.defaultsKey))
        XCTAssertTrue(relauncher.requests.isEmpty)
        XCTAssertEqual(terminations.count, 0)
        XCTAssertFalse(service.isClearPending)
    }

    // MARK: Relaunch script

    func testRelaunchArgumentsPassBundlePathAndPIDWithoutInterpolation() throws {
        let bundlePath = "/Users/Test User/Apps \"Beta\"/Micro's $(Gravity) `x`.app"
        let request = try SettingsRelaunchRequest(bundlePath: bundlePath, processID: 4242)

        XCTAssertEqual(request.executablePath, "/bin/sh")
        XCTAssertEqual(request.arguments.count, 5)
        XCTAssertEqual(request.arguments[0], "-c")
        XCTAssertEqual(request.arguments[3], "4242")
        XCTAssertEqual(request.arguments[4], bundlePath, "The path must arrive as one argv entry, unchanged")
        XCTAssertFalse(request.arguments[1].contains(bundlePath))
        XCTAssertFalse(request.arguments[1].contains("4242"))
        XCTAssertTrue(request.arguments[1].contains("kill -0 \"$1\""))
        XCTAssertTrue(request.arguments[1].contains("exec /usr/bin/open -n \"$2\""))
    }

    func testRelaunchRejectsRelativePathsAndNonPositivePIDs() {
        XCTAssertThrowsError(try SettingsRelaunchRequest(bundlePath: "Microgravity.app", processID: 1))
        XCTAssertThrowsError(try SettingsRelaunchRequest(bundlePath: "/Applications/Microgravity", processID: 1))
        XCTAssertThrowsError(try SettingsRelaunchRequest(bundlePath: "/Applications/Microgravity.app", processID: 0))
        XCTAssertThrowsError(try SettingsRelaunchRequest(bundlePath: "/Applications/Microgravity.app", processID: -3))
    }
}
