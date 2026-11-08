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
        #endif

        let store = DefaultMonitoringStore(
            collector: SystemMonitorCollector(advancedCollector: NativeAdvancedMetricsCollector()),
            historyStore: SQLiteMonitoringHistoryStore()
        )
        let storedInterval = UserDefaults.standard.double(forKey: SamplingControls.refreshIntervalDefaultsKey)
        let interval = MonitoringInterval(rawValue: storedInterval) ?? .oneSecond
        store.start(interval: interval)
        return AppDependencies(
            monitoringStore: store,
            processActions: PrivilegedProcessActionController(),
            integrations: NativeSystemIntegrationAPI(),
            fixtureMode: false
        )
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
    private static var isFixtureUITest: Bool {
        let process = ProcessInfo.processInfo
        let arguments = process.arguments
        let environment = process.environment
        let hasTestRunnerMarker = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
        return hasTestRunnerMarker && arguments.contains("--ui-test-fixtures")
    }
    #endif
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
