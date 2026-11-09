import AppKit
import Foundation

/// The answer to the "Reset all settings?" sheet. Anything other than the first button keeps every setting.
enum SettingsResetDecision: Equatable {
    case resetAndRestart
    case cancel

    init(response: NSApplication.ModalResponse) {
        self = response == .alertFirstButtonReturn ? .resetAndRestart : .cancel
    }
}

enum SettingsResetError: Error, Equatable {
    /// The restart could not be prepared. Nothing was changed.
    case restartUnavailable
    /// Settings were cleared, but the restart could not be started. The app stays open.
    case restartFailed

    var messageText: String {
        switch self {
        case .restartUnavailable: return String(localized: "Settings were not reset")
        case .restartFailed: return String(localized: "Microgravity could not restart")
        }
    }

    var informativeText: String {
        switch self {
        case .restartUnavailable:
            return String(localized: "Microgravity could not prepare to restart, so nothing was changed. Try again.")
        case .restartFailed:
            return String(localized: "Your settings were reset. Quit and open Microgravity again to use them.")
        }
    }
}

/// The detached shell job that reopens the app after this process exits.
///
/// The PID and bundle path travel as argv entries (`$1` and `$2`), never as script text, so spaces and quotes in the path are safe.
struct SettingsRelaunchRequest: Equatable {
    static let shellPath = "/bin/sh"
    static let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n "$2""#

    let executablePath: String
    let arguments: [String]

    init(bundlePath: String, processID: Int32) throws {
        guard processID > 0, bundlePath.hasPrefix("/"), bundlePath.hasSuffix(".app") else {
            throw SettingsResetError.restartUnavailable
        }
        executablePath = Self.shellPath
        arguments = ["-c", Self.script, "relaunch", String(processID), bundlePath]
    }
}

/// Starts the detached relaunch job. Tests and fixture runs inject a relauncher that never starts anything.
@MainActor
protocol SettingsRelauncher {
    func relaunch(_ request: SettingsRelaunchRequest) throws
}

@MainActor
struct ProcessSettingsRelauncher: SettingsRelauncher {
    func relaunch(_ request: SettingsRelaunchRequest) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor
struct SuppressedSettingsRelauncher: SettingsRelauncher {
    func relaunch(_ request: SettingsRelaunchRequest) throws {}
}

/// Resets every Microgravity setting by removing the app's defaults domain, then restarts the app.
///
/// Only that defaults domain is touched. The history database, the privileged helper and login items are left alone.
@MainActor
final class SettingsResetService {
    static let shared = makeLive()

    private let defaults: UserDefaults
    private let domainName: String
    private let bundleURL: URL
    private let processID: Int32
    private let relauncher: any SettingsRelauncher
    private let terminate: @MainActor () -> Void

    /// Set by a reset. Windows and table autosave can write values back until the app quits, so quit clears again.
    private(set) var isClearPending = false

    init(defaults: UserDefaults, domainName: String, bundleURL: URL, processID: Int32,
         relauncher: any SettingsRelauncher, terminate: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.domainName = domainName
        self.bundleURL = bundleURL
        self.processID = processID
        self.relauncher = relauncher
        self.terminate = terminate
    }

    /// Applies the sheet's answer. `.cancel` changes nothing and calls nothing.
    ///
    /// The restart is validated before anything is cleared. If the relauncher fails after the clear, the app
    /// stays open and the error says the settings were reset. It only quits after the relauncher succeeds.
    func apply(_ decision: SettingsResetDecision) throws {
        guard decision == .resetAndRestart else { return }
        let request = try SettingsRelaunchRequest(bundlePath: bundleURL.path, processID: processID)
        isClearPending = true
        clearDomain()
        do {
            try relauncher.relaunch(request)
        } catch {
            throw SettingsResetError.restartFailed
        }
        terminate()
    }

    /// Runs at quit. Clears again so values written since the reset (window frames, table columns) do not survive.
    func clearAtQuitIfPending() {
        guard isClearPending else { return }
        clearDomain()
    }

    private func clearDomain() {
        guard !domainName.isEmpty else { return }
        defaults.removePersistentDomain(forName: domainName)
        _ = defaults.synchronize()
    }

    /// Production clears `.standard` under the bundle identifier and restarts. DEBUG fixture runs clear their own
    /// suite. XCTest and fixture runs never restart or quit the host.
    private static func makeLive() -> SettingsResetService {
        let environment = ProcessInfo.processInfo.environment
        let isTestRun = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundleInto"]
            .contains { environment[$0] != nil }
        let fixtureSuite = AppComposition.fixtureDefaultsSuiteForCleanup
        let isSuppressed = isTestRun || fixtureSuite != nil
        let target: (defaults: UserDefaults, domainName: String)
        if let fixtureSuite, let suite = UserDefaults(suiteName: fixtureSuite) {
            target = (suite, fixtureSuite)
        } else {
            target = (.standard, Bundle.main.bundleIdentifier ?? "")
        }
        let relauncher: any SettingsRelauncher = isSuppressed ? SuppressedSettingsRelauncher() : ProcessSettingsRelauncher()
        let terminate: @MainActor () -> Void = isSuppressed ? {} : { NSApp.terminate(nil) }
        return SettingsResetService(defaults: target.defaults, domainName: target.domainName,
                                    bundleURL: Bundle.main.bundleURL,
                                    processID: ProcessInfo.processInfo.processIdentifier,
                                    relauncher: relauncher, terminate: terminate)
    }
}
