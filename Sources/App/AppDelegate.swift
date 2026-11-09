import AppKit

@main
enum MicrogravityApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// Answers an application-should-terminate request exactly once, whichever finishes first.
@MainActor
private final class TerminationReplyGate {
    private let application: NSApplication
    private var replied = false

    init(application: NSApplication) {
        self.application = application
    }

    func reply() {
        guard !replied else { return }
        replied = true
        application.reply(toApplicationShouldTerminate: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quit never waits longer than this for buffered history to commit.
    private static let historyFlushTimeout: Duration = .seconds(2)

    private var windowController: MainWindowController?
    private var fixtureDefaultsSuite: String?
    private var monitoringStore: (any MonitoringStore)?
    private var isFixtureMode = false
    private var sleepObserver: NSObjectProtocol?

    private static func fixtureWindowAutosaveName(for suite: String) -> String {
        "Microgravity.UITests.Window.\(suite)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearancePreference.applyCurrent()
        NSApp.mainMenu = MainMenu.make()
        let dependencies = AppComposition.make()
        isFixtureMode = dependencies.fixtureMode
        monitoringStore = dependencies.monitoringStore
        if !dependencies.fixtureMode {
            // Commit buffered history before the Mac sleeps. Best effort: the system may not wait for it.
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.flushHistoryInBackground() }
            }
        }
        if dependencies.fixtureMode {
            fixtureDefaultsSuite = AppComposition.fixtureDefaultsSuiteForCleanup
        }
        let fixtureWindowAutosaveName = fixtureDefaultsSuite.map { Self.fixtureWindowAutosaveName(for: $0) }
        let frameAutosaveName: String?
        if dependencies.fixtureMode {
            // UI fixtures start at declared default size each launch. Production keeps its saved frame.
            frameAutosaveName = nil
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-expansion-state"),
               let fixtureWindowAutosaveName {
                UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(fixtureWindowAutosaveName)")
                _ = UserDefaults.standard.synchronize()
            }
        } else {
            frameAutosaveName = MainWindowController.frameAutosaveName
        }
        let isVisualFixtureRun = dependencies.fixtureMode
            && fixtureDefaultsSuite != nil
            && ProcessInfo.processInfo.arguments.contains("--ui-test-visual-captures")
        windowController = MainWindowController(
            dependencies: dependencies,
            frameAutosaveName: frameAutosaveName,
            identifiesFixtureVisualWindow: isVisualFixtureRun,
            initialContentSize: Self.fixtureWindowContentSize(fixtureMode: dependencies.fixtureMode)
        )
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fixture-only initial size for the minimum-size visual matrix. The window still goes through the production sizing path.
    private static func fixtureWindowContentSize(fixtureMode: Bool) -> NSSize? {
        #if DEBUG
        guard fixtureMode else { return nil }
        return MainWindowController.fixtureContentSize(fromArguments: ProcessInfo.processInfo.arguments)
        #else
        return nil
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if let fixtureDefaultsSuite {
            return clearFixtureDefaults(suite: fixtureDefaultsSuite) ? .terminateNow : .terminateCancel
        }
        #endif
        guard !isFixtureMode, let monitoringStore else { return .terminateNow }
        // Quit waits for the history commit, but never longer than the timeout.
        let gate = TerminationReplyGate(application: sender)
        Task { @MainActor in
            try? await Task.sleep(for: Self.historyFlushTimeout)
            gate.reply()
        }
        Task { @MainActor in
            await monitoringStore.flushHistory()
            gate.reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsResetService.shared.isClearPending {
            // Stop the main window from writing its frame back, then clear whatever it wrote since the reset.
            windowController?.window?.setFrameAutosaveName("")
        }
        SettingsResetService.shared.clearAtQuitIfPending()
        // shouldTerminate already waited for the commit. This is a last attempt for any path that skipped it.
        flushHistoryInBackground()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func flushHistoryInBackground() {
        guard !isFixtureMode, let monitoringStore else { return }
        Task { @MainActor in
            await monitoringStore.flushHistory()
        }
    }

    #if DEBUG
    private func clearFixtureDefaults(suite: String) -> Bool {
        guard AppComposition.isValidFixtureDefaultsSuite(suite),
              let fixtureDefaults = UserDefaults(suiteName: suite) else {
            NSLog("Microgravity UI-test defaults cleanup rejected invalid fixture suite.")
            return false
        }

        fixtureDefaults.removePersistentDomain(forName: suite)

        let autosaveNames = [
            "process.outline.\(suite)",
            "history.outline.\(suite)",
            Self.fixtureWindowAutosaveName(for: suite)
        ]
        let autosavePrefixes = [
            "NSTableView Columns v3 ",
            "NSTableView Sort Ordering v2 ",
            "NSTableView Supports v2 "
        ]
        let autosaveKeys = autosaveNames.flatMap { name in autosavePrefixes.map { $0 + name } }
            + ["NSWindow Frame \(Self.fixtureWindowAutosaveName(for: suite))"]
        for key in autosaveKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        let fixtureSynchronized = fixtureDefaults.synchronize()
        let standardSynchronized = UserDefaults.standard.synchronize()
        let remainingSuiteValues = fixtureDefaults.persistentDomain(forName: suite) ?? [:]
        let remainingAutosaveKeys = autosaveKeys.filter { UserDefaults.standard.object(forKey: $0) != nil }
        guard fixtureSynchronized, standardSynchronized,
              remainingSuiteValues.isEmpty, remainingAutosaveKeys.isEmpty else {
            NSLog("Microgravity UI-test defaults cleanup failed for fixture suite %@.", suite)
            return false
        }
        return true
    }

    #endif
}
