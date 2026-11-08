import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenuItem(title: "Microgravity", items: appItems()))
        menu.addItem(submenuItem(title: String(localized: "File"), items: [
            NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        ]))
        menu.addItem(submenuItem(title: String(localized: "Edit"), items: editItems()))
        menu.addItem(submenuItem(title: String(localized: "View"), items: viewItems()))
        menu.addItem(submenuItem(title: String(localized: "Process"), items: processItems()))

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(submenuItem(menu: windowMenu))
        NSApp.windowsMenu = windowMenu

        // Setting NSApp.helpMenu gives the menu the system Search field.
        let helpMenu = NSMenu(title: String(localized: "Help"))
        helpMenu.addItem(NSMenuItem(title: String(localized: "Microgravity Help"), action: #selector(MainWindowController.showHelp(_:)), keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem(title: String(localized: "Report an Issue…"), action: #selector(MainWindowController.reportIssue(_:)), keyEquivalent: ""))
        menu.addItem(submenuItem(menu: helpMenu))
        NSApp.helpMenu = helpMenu
        return menu
    }

    private static func appItems() -> [NSMenuItem] {
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        let updates = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(MainWindowController.checkForUpdates(_:)), keyEquivalent: "")
        let support = NSMenuItem(title: String(localized: "Support Microgravity…"), action: #selector(MainWindowController.openSupportPage(_:)), keyEquivalent: "")
        let hideOthers = NSMenuItem(title: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        return [
            NSMenuItem(title: String(localized: "About Microgravity"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            settings,
            updates,
            support,
            .separator(),
            NSMenuItem(title: String(localized: "Hide Microgravity"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            hideOthers,
            NSMenuItem(title: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: String(localized: "Quit Microgravity"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        let redo = NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        return [
            NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        var items = DashboardPage.allCases.enumerated().map { index, page in
            let keyEquivalent = index < 9 ? String(index + 1) : ""
            let item = NSMenuItem(title: page.title, action: #selector(MainWindowController.showPage(_:)), keyEquivalent: keyEquivalent)
            item.tag = index
            return item
        }
        items.append(.separator())
        let toggle = NSMenuItem(title: String(localized: "Toggle Sidebar"), action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .option]
        items.append(toggle)
        return items
    }

    /// Actions target the Processes page through the responder chain, so they are disabled elsewhere.
    private static func processItems() -> [NSMenuItem] {
        let find = NSMenuItem(title: String(localized: "Find Process"), action: #selector(ProcessesViewController.focusProcessSearch(_:)), keyEquivalent: "f")
        let quit = NSMenuItem(title: String(localized: "Quit Process"), action: #selector(ProcessesViewController.quitSelectedProcess(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        // No shortcut: ⇧⌥⌘Q is the system Log Out-without-confirmation shortcut.
        let forceQuit = NSMenuItem(title: String(localized: "Force Quit…"), action: #selector(ProcessesViewController.forceQuitSelectedProcess(_:)), keyEquivalent: "")
        let details = NSMenuItem(title: String(localized: "Show in Details"), action: #selector(ProcessesViewController.showSelectedProcessInDetails(_:)), keyEquivalent: "i")
        return [find, .separator(), quit, forceQuit, .separator(), details]
    }

    private static func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        return submenuItem(menu: menu)
    }

    private static func submenuItem(menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
