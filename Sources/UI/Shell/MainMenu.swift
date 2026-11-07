import AppKit

@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenuItem(title: "Microgravity", items: appItems()))
        menu.addItem(submenuItem(title: "File", items: [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        ]))
        menu.addItem(submenuItem(title: "Edit", items: editItems()))
        menu.addItem(submenuItem(title: "View", items: viewItems()))
        menu.addItem(submenuItem(title: "Process", items: processItems()))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        menu.addItem(submenuItem(menu: windowMenu))
        NSApp.windowsMenu = windowMenu

        // An empty help menu still gets the system Search field.
        let helpMenu = NSMenu(title: "Help")
        menu.addItem(submenuItem(menu: helpMenu))
        NSApp.helpMenu = helpMenu
        return menu
    }

    private static func appItems() -> [NSMenuItem] {
        let settings = NSMenuItem(title: "Settings…", action: #selector(MainWindowController.showSettings(_:)), keyEquivalent: ",")
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(MainWindowController.checkForUpdates(_:)), keyEquivalent: "")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        return [
            NSMenuItem(title: "About Microgravity", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            settings,
            updates,
            .separator(),
            NSMenuItem(title: "Hide Microgravity", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            hideOthers,
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit Microgravity", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        return [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        let toggle = NSMenuItem(title: "Toggle Sidebar", action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.command, .option]
        items.append(toggle)
        return items
    }

    /// Actions target the Processes page through the responder chain, so they are disabled elsewhere.
    private static func processItems() -> [NSMenuItem] {
        let find = NSMenuItem(title: "Find Process", action: #selector(ProcessesViewController.focusProcessSearch(_:)), keyEquivalent: "f")
        let quit = NSMenuItem(title: "Quit Process", action: #selector(ProcessesViewController.quitSelectedProcess(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        let forceQuit = NSMenuItem(title: "Force Quit…", action: #selector(ProcessesViewController.forceQuitSelectedProcess(_:)), keyEquivalent: "q")
        forceQuit.keyEquivalentModifierMask = [.command, .option, .shift]
        let details = NSMenuItem(title: "Show in Details", action: #selector(ProcessesViewController.showSelectedProcessInDetails(_:)), keyEquivalent: "i")
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
