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
    static func make() -> AppDependencies {
        #if DEBUG
        if isFixtureUITest {
            let arguments = ProcessInfo.processInfo.arguments
            let fixture = FixtureConfiguration(arguments: arguments)
            let store = FixtureMonitoringStore(configuration: fixture)
            store.start(interval: .oneSecond)
            return AppDependencies(
                monitoringStore: store,
                processActions: FixtureProcessActioner(configuration: fixture),
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

    static func current() -> String {
        UserDefaults.standard.string(forKey: key) ?? "system"
    }

    static func apply(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
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
