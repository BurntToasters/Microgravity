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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var fixtureDefaultsSuite: String?

    private static func fixtureWindowAutosaveName(for suite: String) -> String {
        "Microgravity.UITests.Window.\(suite)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearancePreference.applyCurrent()
        NSApp.mainMenu = MainMenu.make()
        let dependencies = AppComposition.make()
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
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
