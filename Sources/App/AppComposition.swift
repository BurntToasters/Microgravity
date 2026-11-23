import AppKit
import Foundation

@MainActor
struct AppDependencies {
    let monitoringStore: any MonitoringStore
    let processActions: any ProcessActioning
    let integrations: any SystemIntegrationAPI
    let fixtureMode: Bool
}

/// Single composition point for production and isolated UI-test dependencies.
@MainActor
enum AppComposition {
    private static let fixtureDefaultsSuitePrefix = "Microgravity.UITests."

    static func make() -> AppDependencies {
        #if DEBUG
        if isFixtureUITest {
            let arguments = ProcessInfo.processInfo.arguments
            let fixture = FixtureConfiguration(arguments: arguments)
            let store = FixtureMonitoringStore(configuration: fixture)
            store.start(interval: .oneSecond)
            let processActions = FixtureProcessActioner(configuration: fixture) { identity in
                store.removeProcessForFixtureAction(identity)
            }
            return AppDependencies(
                monitoringStore: store,
                processActions: processActions,
                integrations: UnavailableSystemIntegrationAPI(),
                fixtureMode: true
            )
        }
        if isXCTestHost {
            // Core unit tests run with this app as their host. The inert composition never samples,
            // never writes the user's history database, and never touches privileged or system services.
            return AppDependencies(
                monitoringStore: DefaultMonitoringStore(collector: SystemMonitorCollector()),
                processActions: LocalProcessActionController(),
                integrations: UnavailableSystemIntegrationAPI(),
                fixtureMode: false
            )
        }
        #endif

        let localNettopStream = NettopStreamService()
        let ioReportCollector = IOReportCollector()
        let hardwareSpecReader = HardwareSpecReader()
        let workspaceApps = WorkspaceRegularAppCache()
        let advancedCollector = NativeAdvancedMetricsCollector(
            localNettopStream: localNettopStream,
            shouldSamplePowermetrics: {
                #if arch(arm64)
                return !ioReportCollector.hasHardwareChannels
                #else
                return true
                #endif
            }
        )
        let store = DefaultMonitoringStore(
            collector: SystemMonitorCollector(
                advancedCollector: advancedCollector,
                ioReportCollector: ioReportCollector,
                hardwareSpecReader: hardwareSpecReader,
                powerCollector: { components, timestamp in
                    PowerTelemetryCollector.collect(components: components, at: timestamp)
                },
                regularAppPIDsProvider: { workspaceApps.currentPIDs }
            ),
            historyStore: SQLiteMonitoringHistoryStore()
        )
        let storedInterval = UserDefaults.standard.double(forKey: SamplingControls.refreshIntervalDefaultsKey)
        let interval = MonitoringInterval(rawValue: storedInterval) ?? .oneSecond
        store.start(interval: interval)
        observeAppActivation(advancedCollector, localNettopStream: localNettopStream)
        return AppDependencies(
            monitoringStore: store,
            processActions: PrivilegedProcessActionController(),
            integrations: NativeSystemIntegrationAPI(),
            fixtureMode: false
        )
    }

    /// The helper is approved in System Settings, outside the app, so activation is when a retry is most likely to succeed.
    /// Also cleanly tears down the unprivileged fallback stream if the app terminates.
    private static func observeAppActivation(_ collector: NativeAdvancedMetricsCollector,
                                             localNettopStream: NettopStreamService) {
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak collector] _ in
            guard let collector else { return }
            Task { await collector.retryHelperSoon() }
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { _ in
            localNettopStream.stop()
        }
    }

    static var fixtureDefaultsSuiteForCleanup: String? {
        #if DEBUG
        guard isFixtureUITest,
              let suite = ProcessInfo.processInfo.environment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"],
              isValidFixtureDefaultsSuite(suite) else {
            return nil
        }
        return suite
        #else
        return nil
        #endif
    }

    static func isValidFixtureDefaultsSuite(_ suite: String) -> Bool {
        guard suite.hasPrefix(fixtureDefaultsSuitePrefix) else { return false }
        let methodName = suite.dropFirst(fixtureDefaultsSuitePrefix.count)
        let bytes = Array(methodName.utf8)
        guard methodName.hasPrefix("test"), bytes.count > 4 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 95
        }
    }

    #if DEBUG
    private static var isXCTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    private static var isFixtureUITest: Bool {
        isXCTestHost && ProcessInfo.processInfo.arguments.contains("--ui-test-fixtures")
    }
    #endif
}

/// Thread-safe cache of GUI `.regular` application PIDs updated from `NSWorkspace` notifications on main actor.
private final class WorkspaceRegularAppCache: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<Int32>

    @MainActor
    init() {
        self.pids = Self.readRegularPIDs()
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshOnMainActor()
                }
            }
        }
    }

    var currentPIDs: Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }

    @MainActor
    private func refreshOnMainActor() {
        let updated = Self.readRegularPIDs()
        lock.lock()
        pids = updated
        lock.unlock()
    }

    @MainActor
    private static func readRegularPIDs() -> Set<Int32> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier > 0 }
                .map(\.processIdentifier)
        )
    }
}

@MainActor
enum AppearancePreference {
    private static let key = "monitoring.appearance"

    private static var defaults: UserDefaults {
        #if DEBUG
        if let suite = AppComposition.fixtureDefaultsSuiteForCleanup,
           let fixtureDefaults = UserDefaults(suiteName: suite) {
            return fixtureDefaults
        }
        #endif
        return .standard
    }

    static func current() -> String {
        defaults.string(forKey: key) ?? "system"
    }

    static func apply(_ value: String) {
        defaults.set(value, forKey: key)
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static func applyCurrent() {
        apply(current())
    }
}
