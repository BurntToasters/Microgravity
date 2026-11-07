import XCTest

@MainActor
final class MicrogravityUITests: XCTestCase {
    func testProcessesExpandSearchSortAndKeepSelectionIdentity() {
        let app = launchFixture()

        XCTAssertTrue(element("process.table", in: app).waitForExistence(timeout: 5))
        let group = row("process.group.fixture-editor", in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        toggleGroup("process.group.fixture-editor", in: app)

        let child = row("process.row.410", in: "process.table", app: app)
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        child.click()
        XCTAssertTrue(app.staticTexts["process.selection.identity"].waitForExistence(timeout: 3))
        let selectedIdentity = app.staticTexts["process.selection.identity"].label
        XCTAssertTrue(selectedIdentity.contains("pid=410"), "Unexpected selected identity: \(selectedIdentity)")

        // The search field lives in the window toolbar, so match it by identifier rather than element type.
        let search = element("process.search", in: app)
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("Renderer")
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).waitForExistence(timeout: 3))
        XCTAssertFalse(row("process.row.620", in: "process.table", app: app).exists)

        let cpuHeader = element("process.column.cpu", in: app)
        XCTAssertTrue(cpuHeader.exists)
        clickColumnHeader(cpuHeader)
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
        attachScreenshot(app, named: "Processes")
    }

    func testDuplicateGroupTitlesExpandTheClickedGroup() {
        let app = launchFixture(arguments: ["--ui-test-duplicate-groups"])
        let firstGroup = row("process.group.fixture-editor.pid-410-start-1700000001-10000", in: "process.table", app: app)
        let secondGroup = row("process.group.fixture-editor.pid-620-start-1700000003-30000", in: "process.table", app: app)
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(secondGroup.waitForExistence(timeout: 3))
        toggleGroup("process.group.fixture-editor.pid-620-start-1700000003-30000", in: app)
        XCTAssertTrue(row("process.row.620", in: "process.table", app: app).waitForExistence(timeout: 3))
        XCTAssertFalse(row("process.row.410", in: "process.table", app: app).exists)
    }

    func testDuplicateGroupTitlesHaveDistinctNativeRowsLabelsAndToggles() {
        let app = launchFixture(arguments: ["--ui-test-duplicate-groups"])
        let firstID = "process.group.fixture-editor.pid-410-start-1700000001-10000"
        let secondID = "process.group.fixture-editor.pid-620-start-1700000003-30000"
        let firstRow = row(firstID, in: "process.table", app: app)
        let secondRow = row(secondID, in: "process.table", app: app)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 3))
        if firstRow.exists && secondRow.exists {
            XCTAssertNotEqual(firstRow.frame, secondRow.frame)
        }

        let firstLabel = app.staticTexts.matching(identifier: firstID + ".name")
        let secondLabel = app.staticTexts.matching(identifier: secondID + ".name")
        XCTAssertEqual(firstLabel.count, 1)
        XCTAssertEqual(secondLabel.count, 1)
        XCTAssertNotEqual(firstLabel.firstMatch.identifier, secondLabel.firstMatch.identifier)

        XCTAssertEqual(firstRow.descendants(matching: .disclosureTriangle).count, 1)
        XCTAssertEqual(secondRow.descendants(matching: .disclosureTriangle).count, 1)
    }

    func testGroupExpansionPersistsAcrossAppRelaunch() {
        let app = launchFixture()
        let groupID = "process.group.fixture-editor"
        let group = row(groupID, in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        toggleGroup(groupID, in: app)
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(element("navigation.item.processes", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).waitForExistence(timeout: 3))
    }

    func testSelectionSurvivesSnapshotRefresh() {
        let app = launchFixture(arguments: ["--ui-test-refresh-pulse"])
        toggleGroup("process.group.fixture-editor", in: app)
        row("process.row.410", in: "process.table", app: app).click()
        let identity = app.staticTexts["process.selection.identity"].label
        let freshness = app.staticTexts["process.freshness"]
        let original = freshness.label
        let changed = expectation(for: NSPredicate(format: "label != %@", original), evaluatedWith: freshness)
        wait(for: [changed], timeout: 16)
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, identity)
        XCTAssertTrue(element("process.action.quit", in: app).isEnabled)
    }

    func testProcessContextMenuTargetsRightClickedRow() {
        let app = launchFixture()
        let group = row("process.group.fixture-editor", in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        toggleGroup("process.group.fixture-editor", in: app)
        let process = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(process.waitForExistence(timeout: 3))
        process.rightClick()
        let outline = app.outlines.matching(identifier: "process.table").firstMatch
        let quit = outline.descendants(matching: .menuItem).matching(identifier: "quitSelectedProcess:").firstMatch
        let force = outline.descendants(matching: .menuItem).matching(identifier: "forceQuitSelectedProcess:").firstMatch
        XCTAssertTrue(quit.waitForExistence(timeout: 3))
        XCTAssertTrue(quit.isEnabled)
        XCTAssertTrue(force.isEnabled)
        XCTAssertTrue(app.staticTexts["process.selection.identity"].label.contains("pid=411"))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testShowInDetailsSelectsTheRightClickedProcess() {
        let app = launchFixture()
        toggleGroup("process.group.fixture-editor", in: app)
        let process = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(process.waitForExistence(timeout: 3))
        process.rightClick()

        let showInDetails = app.outlines.matching(identifier: "process.table").firstMatch
            .descendants(matching: .menuItem).matching(identifier: "showSelectedProcessInDetails:").firstMatch
        XCTAssertTrue(showInDetails.waitForExistence(timeout: 3))
        showInDetails.click()

        let detailsRow = row("details.process.411", in: "details.table", app: app)
        XCTAssertTrue(detailsRow.waitForExistence(timeout: 3))
        XCTAssertTrue(detailsRow.isSelected)
    }

    func testForceQuitRevalidatesIdentityAfterPidReuse() {
        let app = launchFixture(arguments: ["--ui-test-stale-target"])

        toggleGroup("process.group.fixture-editor", in: app)
        row("process.row.410", in: "process.table", app: app).click()
        // Confirmation and error dialogs are sheets attached to the window.
        element("process.action.force-quit", in: app).click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        element("process.force-quit.confirm", in: app).click()

        let staleText = app.staticTexts["The selected process changed or exited. No process was terminated."]
        XCTAssertTrue(staleText.waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["OK"].click()
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, "No process selected")
        attachScreenshot(app, named: "Stale process action")
    }

    func testPerformanceSeparatesUnsupportedMetricsFromZero() {
        let app = launchFixture(arguments: ["--ui-test-gpu-unavailable", "--ui-test-energy-unavailable"])

        element("navigation.item.performance", in: app).click()
        XCTAssertTrue(element("performance.graph.cpu-total", in: app).waitForExistence(timeout: 3))
        let cpuGraph = element("performance.graph.cpu-total", in: app)
        XCTAssertTrue(cpuGraph.label.localizedCaseInsensitiveContains("percentage"))

        // The detail card shows one metric at a time, so each rail row is selected before its graphs are checked.
        element("performance.rail.cpu.title", in: app).click()
        element("performance.cpu.mode", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        XCTAssertTrue(element("performance.graph.cpu-cores", in: app).waitForExistence(timeout: 3))
        element("performance.cpu.mode", in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        element("performance.rail.memory.title", in: app).click()
        XCTAssertTrue(element("performance.graph.memory-pressure", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("performance.graph.swap", in: app).exists)
        element("performance.rail.disk.title", in: app).click()
        XCTAssertTrue(element("performance.graph.disk", in: app).waitForExistence(timeout: 3))
        element("performance.rail.network.title", in: app).click()
        XCTAssertTrue(element("performance.graph.network", in: app).waitForExistence(timeout: 3))
        element("performance.rail.gpu.title", in: app).click()
        XCTAssertTrue(app.staticTexts["performance.gpu.state"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["performance.gpu.state"].label.contains("Unsupported"))
        element("performance.rail.energy.title", in: app).click()
        XCTAssertTrue(app.staticTexts["performance.energy.state"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["performance.energy.state"].label.contains("Unsupported"))

        element("performance.action.pause", in: app).click()
        XCTAssertTrue(app.staticTexts["performance.sampling-state"].label.contains("Paused"))
        attachScreenshot(app, named: "Performance")
    }

    func testHistoryShowsGapsAndRequiresConfirmationToReset() {
        let app = launchFixture(arguments: ["--ui-test-history-gap"])

        element("navigation.item.history", in: app).click()
        XCTAssertTrue(element("history.range.30-days", in: app).waitForExistence(timeout: 3))
        let gap = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "history.gap.")
        ).firstMatch
        XCTAssertTrue(gap.exists)
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).exists)

        element("history.action.reset", in: app).click()
        // Reset confirmation is an NSAlert presented as a sheet on the window (U14); it may surface as a sheet or an alert.
        let confirmation = app.sheets.firstMatch.waitForExistence(timeout: 3)
            ? app.sheets.firstMatch
            : app.alerts["Reset App History"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).exists)
        attachScreenshot(app, named: "App History")
    }

    func testHistorySortsFormattedTotalsByNumericValues() {
        let app = launchFixture()
        element("navigation.item.history", in: app).click()

        let editor = app.staticTexts["history.total.fixture-editor.application"]
        let indexer = app.staticTexts["history.total.fixture-indexer.application"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(indexer.waitForExistence(timeout: 3))
        let cpuHeader = app.descendants(matching: .any).matching(identifier: "cpu").firstMatch
        XCTAssertTrue(cpuHeader.exists)
        clickColumnHeader(cpuHeader)

        XCTAssertLessThan(indexer.frame.minY, editor.frame.minY)
    }

    func testStartupAndServicesAreReadOnlyAndLabelIncompleteDiscovery() {
        let app = launchFixture(arguments: ["--ui-test-incomplete-discovery"])

        element("navigation.item.startup", in: app).click()
        XCTAssertTrue(element("startup.discovery-state", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["startup.discovery-state"].label.contains("Some startup locations could not be inspected."))
        XCTAssertTrue(row("startup.item.fixture-agent", in: "startup.table", app: app).exists)
        row("startup.item.fixture-agent", in: "startup.table", app: app).click()
        XCTAssertTrue(element("startup.action.reveal-path.fixture-agent", in: app).exists)
        XCTAssertFalse(element("startup.action.disable.fixture-agent", in: app).exists)
        attachScreenshot(app, named: "Startup")

        element("navigation.item.services", in: app).click()
        XCTAssertTrue(element("services.discovery-state", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("services.item.fixture-service.name", in: app).exists)
        XCTAssertFalse(element("services.action.stop.fixture-service", in: app).exists)
        attachScreenshot(app, named: "Services")
    }

    func testUsersShowsSessionsAndResourceAggregatesWithoutAccountActions() {
        let app = launchFixture()

        element("navigation.item.users", in: app).click()
        XCTAssertTrue(element("users.table", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(row("users.row.fixture-user", in: "users.table", column: "user", app: app).exists)
        XCTAssertEqual(app.staticTexts["users.row.fixture-user.user"].label, "fixture-user")
        XCTAssertEqual(app.staticTexts["users.row.fixture-user.user.badge"].label, "You")
        XCTAssertTrue(app.staticTexts["users.row.fixture-user.process-count"].exists)
        XCTAssertTrue(app.staticTexts["users.row.fixture-user.memory"].exists)
        XCTAssertFalse(element("users.action.manage-account", in: app).exists)
        attachScreenshot(app, named: "Users")
    }

    func testDetailsIsFlatAndShowsUnavailableMetricsExplicitly() {
        let app = launchFixture(arguments: ["--ui-test-network-unavailable"])

        element("navigation.item.details", in: app).click()
        XCTAssertTrue(element("details.table", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("details.process.410.name", in: app).exists)
        XCTAssertTrue(app.staticTexts["details.process.410.owner"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.parent"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.path"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.disk"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.memory"].exists)
        // The Network column is hidden while its capability is unavailable; the banner keeps the explicit reason.
        XCTAssertFalse(app.staticTexts["details.process.410.network"].exists)
        XCTAssertTrue(app.staticTexts["details.capability-state"].label.contains("Unsupported"))
        XCTAssertFalse(element("details.group.fixture-editor", in: app).exists)
        attachScreenshot(app, named: "Details")
    }

    func testDetailsKeepsSelectedProcessAcrossSnapshotRefresh() {
        let app = launchFixture(arguments: ["--ui-test-refresh-pulse"])
        element("navigation.item.details", in: app).click()
        let selectedRow = row("details.process.410", in: "details.table", app: app)
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 3))
        selectedRow.click()
        XCTAssertTrue(selectedRow.isSelected)

        let capability = app.staticTexts["details.capability-state"]
        let original = capability.label
        let changed = expectation(for: NSPredicate(format: "label != %@", original), evaluatedWith: capability)
        wait(for: [changed], timeout: 16)

        XCTAssertTrue(row("details.process.410", in: "details.table", app: app).isSelected)
    }

    func testSettingsExposeSupportedChoicesAndUnavailableIntegrationsHonestly() {
        let app = launchFixture(arguments: ["--ui-test-integrations-unavailable"])

        element("navigation.item.settings", in: app).click()
        XCTAssertTrue(app.popUpButtons.matching(identifier: "settings.appearance").firstMatch.waitForExistence(timeout: 3))
        assertPopUpOffers(["settings.appearance.system", "settings.appearance.light", "settings.appearance.dark"],
                          in: "settings.appearance", app: app)
        assertPopUpOffers(["settings.refresh.0.5", "settings.refresh.1", "settings.refresh.2", "settings.refresh.5"],
                          in: "settings.refresh", app: app)
        XCTAssertTrue(app.staticTexts["settings.helper.state"].label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["settings.login-item.state"].label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["settings.updates.state"].label.contains("Unavailable"))
        attachScreenshot(app, named: "Settings")
    }

    func testAppearanceSwitchChangesWindowAndCanReturnToSystem() {
        let app = launchFixture()
        element("navigation.item.settings", in: app).click()
        XCTAssertTrue(app.popUpButtons.matching(identifier: "settings.appearance").firstMatch.waitForExistence(timeout: 3))
        choosePopUpItem("settings.appearance.light", in: "settings.appearance", app: app)
        let lightImage = app.screenshot().pngRepresentation
        attachScreenshot(app, named: "Settings light appearance")
        choosePopUpItem("settings.appearance.dark", in: "settings.appearance", app: app)
        let darkImage = app.screenshot().pngRepresentation
        attachScreenshot(app, named: "Settings dark appearance")
        XCTAssertNotEqual(lightImage, darkImage)
        choosePopUpItem("settings.appearance.system", in: "settings.appearance", app: app)
    }

    func testClosingLastWindowTerminatesTheApplication() {
        let app = launchFixture()

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixtures"] + arguments
        let defaultsSuite = "Microgravity.UITests.\(UUID().uuidString)"
        app.launchEnvironment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"] = defaultsSuite
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "MicrogravityUITests.xctest"
        app.launch()
        // The XCTest runner keeps focus on macOS; without an explicit
        // activation XCUITest refuses taps ("not foreground").
        for _ in 0..<50 where app.state != .runningForeground {
            app.activate()
            usleep(100_000)
        }
        XCTAssertTrue(element("navigation.item.processes", in: app).waitForExistence(timeout: 5))
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func row(_ identifier: String, in tableIdentifier: String, column: String = "name",
                     app: XCUIApplication) -> XCUIElement {
        // AppKit publishes synthetic rows without the row view's AX identifier, so resolve the native row through its identified label.
        // The Processes page is an NSOutlineView (outline rows); the other tables are NSTableViews.
        let outline = app.outlines.matching(identifier: tableIdentifier).firstMatch
        if outline.exists {
            return outline.descendants(matching: .outlineRow)
                .containing(.staticText, identifier: identifier + "." + column).firstMatch
        }
        return app.tables.matching(identifier: tableIdentifier).firstMatch.descendants(matching: .tableRow)
            .containing(.staticText, identifier: identifier + "." + column).firstMatch
    }

    private func toggleGroup(_ groupIdentifier: String, in app: XCUIApplication) {
        let group = row(groupIdentifier, in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3), groupIdentifier)
        let disclosure = group.descendants(matching: .disclosureTriangle).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3), groupIdentifier)
        disclosure.click()
    }

    private func clickColumnHeader(_ header: XCUIElement) {
        XCTAssertTrue(header.exists)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.015)).click()
    }

    /// Opens a pop-up and checks that each item identifier is offered. Settings pop-up items are menu items, not views.
    private func assertPopUpOffers(_ itemIdentifiers: [String], in popUpIdentifier: String, app: XCUIApplication) {
        let popUp = app.popUpButtons.matching(identifier: popUpIdentifier).firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 3))
        popUp.click()
        for itemIdentifier in itemIdentifiers {
            XCTAssertTrue(app.menuItems.matching(identifier: itemIdentifier).firstMatch.waitForExistence(timeout: 3), itemIdentifier)
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Opens a pop-up and picks the menu item with `itemIdentifier`.
    private func choosePopUpItem(_ itemIdentifier: String, in popUpIdentifier: String, app: XCUIApplication) {
        let popUp = app.popUpButtons.matching(identifier: popUpIdentifier).firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 3))
        popUp.click()
        let item = app.menuItems.matching(identifier: itemIdentifier).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), itemIdentifier)
        item.click()
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "UI - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
