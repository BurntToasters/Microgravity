import XCTest

@MainActor
final class MicrogravityUITests: XCTestCase {
    func testProcessesExpandSearchSortAndKeepSelectionIdentity() {
        let app = launchFixture()

        XCTAssertTrue(element("process.table", in: app).waitForExistence(timeout: 5))
        let group = element("process.group.fixture-editor", in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        element("process.group.toggle.fixture-editor", in: app).tap()

        let child = element("process.row.410", in: app)
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        child.tap()
        XCTAssertTrue(app.staticTexts["process.selection.identity"].waitForExistence(timeout: 3))
        let selectedIdentity = app.staticTexts["process.selection.identity"].label
        XCTAssertTrue(selectedIdentity.contains("pid=410"))

        let search = app.textFields["process.search"]
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("Renderer")
        XCTAssertTrue(element("process.row.410", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("process.row.620", in: app).exists)

        element("process.column.cpu", in: app).tap()
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
        attachScreenshot(app, named: "Processes")
    }

    func testDuplicateGroupTitlesExpandTheClickedGroup() {
        let app = launchFixture(arguments: ["--ui-test-duplicate-groups"])
        let toggles = app.buttons.matching(identifier: "process.group.toggle.fixture-editor")
        XCTAssertTrue(toggles.element(boundBy: 1).waitForExistence(timeout: 3))
        toggles.element(boundBy: 1).tap()
        XCTAssertTrue(element("process.row.620", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("process.row.410", in: app).exists)
    }

    func testSelectionSurvivesSnapshotRefresh() {
        let app = launchFixture(arguments: ["--ui-test-refresh-pulse"])
        element("process.group.toggle.fixture-editor", in: app).tap()
        element("process.row.410", in: app).tap()
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
        let group = element("process.group.fixture-editor", in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.rightClick()
        XCTAssertTrue(app.menuItems["Quit Process"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Force Quit…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testForceQuitRevalidatesIdentityAfterPidReuse() {
        let app = launchFixture(arguments: ["--ui-test-stale-target"])

        element("process.group.toggle.fixture-editor", in: app).tap()
        element("process.row.410", in: app).tap()
        element("process.action.force-quit", in: app).tap()
        let confirmation = app.alerts["Confirm Force Quit"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Force Quit"].tap()

        let stale = app.alerts["Process No Longer Available"]
        XCTAssertTrue(stale.waitForExistence(timeout: 3))
        XCTAssertTrue(stale.staticTexts["The selected process changed or exited. No process was terminated."].exists)
        stale.buttons["OK"].tap()
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, "No process selected")
        attachScreenshot(app, named: "Stale process action")
    }

    func testPerformanceSeparatesUnsupportedMetricsFromZero() {
        let app = launchFixture(arguments: ["--ui-test-gpu-unavailable", "--ui-test-energy-unavailable"])

        element("navigation.item.performance", in: app).tap()
        XCTAssertTrue(element("performance.graph.cpu-total", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("performance.graph.cpu-cores", in: app).exists)
        XCTAssertTrue(element("performance.graph.memory-pressure", in: app).exists)
        XCTAssertTrue(element("performance.graph.swap", in: app).exists)
        XCTAssertTrue(element("performance.graph.disk", in: app).exists)
        XCTAssertTrue(element("performance.graph.network", in: app).exists)
        XCTAssertTrue(app.staticTexts["performance.gpu.state"].label.contains("Unsupported"))
        XCTAssertTrue(app.staticTexts["performance.energy.state"].label.contains("Unsupported"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "percent")).firstMatch.exists)

        element("performance.action.pause", in: app).tap()
        XCTAssertTrue(app.staticTexts["performance.sampling-state"].label.contains("Paused"))
        attachScreenshot(app, named: "Performance")
    }

    func testHistoryShowsGapsAndRequiresConfirmationToReset() {
        let app = launchFixture(arguments: ["--ui-test-history-gap"])

        element("navigation.item.history", in: app).tap()
        XCTAssertTrue(element("history.range.30-days", in: app).waitForExistence(timeout: 3))
        let gap = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "history.gap.")
        ).firstMatch
        XCTAssertTrue(gap.exists)
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).exists)

        element("history.action.reset", in: app).tap()
        let confirmation = app.alerts["Reset App History"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).exists)
        attachScreenshot(app, named: "App History")
    }

    func testStartupAndServicesAreReadOnlyAndLabelIncompleteDiscovery() {
        let app = launchFixture(arguments: ["--ui-test-incomplete-discovery"])

        element("navigation.item.startup", in: app).tap()
        XCTAssertTrue(element("startup.discovery-state", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["startup.discovery-state"].label.contains("Some startup locations could not be inspected."))
        XCTAssertTrue(element("startup.item.fixture-agent", in: app).exists)
        element("startup.item.fixture-agent.name", in: app).tap()
        XCTAssertTrue(element("startup.action.reveal-path.fixture-agent", in: app).exists)
        XCTAssertFalse(element("startup.action.disable.fixture-agent", in: app).exists)
        attachScreenshot(app, named: "Startup")

        element("navigation.item.services", in: app).tap()
        XCTAssertTrue(element("services.discovery-state", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("services.item.fixture-service.name", in: app).exists)
        XCTAssertFalse(element("services.action.stop.fixture-service", in: app).exists)
        attachScreenshot(app, named: "Services")
    }

    func testUsersShowsSessionsAndResourceAggregatesWithoutAccountActions() {
        let app = launchFixture()

        element("navigation.item.users", in: app).tap()
        XCTAssertTrue(element("users.table", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("users.row.fixture-user", in: app).exists)
        XCTAssertTrue(app.staticTexts["users.row.fixture-user.process-count"].exists)
        XCTAssertTrue(app.staticTexts["users.row.fixture-user.memory"].exists)
        XCTAssertFalse(element("users.action.manage-account", in: app).exists)
        attachScreenshot(app, named: "Users")
    }

    func testDetailsIsFlatAndShowsUnavailableMetricsExplicitly() {
        let app = launchFixture(arguments: ["--ui-test-network-unavailable"])

        element("navigation.item.details", in: app).tap()
        XCTAssertTrue(element("details.table", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("details.process.410.name", in: app).exists)
        XCTAssertTrue(app.staticTexts["details.process.410.owner"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.parent"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.path"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.disk"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.memory"].exists)
        XCTAssertTrue(app.staticTexts["details.process.410.network"].label.contains("Unsupported"))
        XCTAssertFalse(element("details.group.fixture-editor", in: app).exists)
        attachScreenshot(app, named: "Details")
    }

    func testSettingsExposeSupportedChoicesAndUnavailableIntegrationsHonestly() {
        let app = launchFixture(arguments: ["--ui-test-integrations-unavailable"])

        element("navigation.item.settings", in: app).tap()
        XCTAssertTrue(element("settings.appearance.system", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("settings.appearance.light", in: app).exists)
        XCTAssertTrue(element("settings.appearance.dark", in: app).exists)
        XCTAssertTrue(element("settings.refresh.0.5", in: app).exists)
        XCTAssertTrue(element("settings.refresh.1", in: app).exists)
        XCTAssertTrue(element("settings.refresh.2", in: app).exists)
        XCTAssertTrue(element("settings.refresh.5", in: app).exists)
        XCTAssertTrue(app.staticTexts["settings.helper.state"].label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["settings.login-item.state"].label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["settings.updates.state"].label.contains("Unavailable"))
        attachScreenshot(app, named: "Settings")
    }

    func testAppearanceSwitchChangesWindowAndCanReturnToSystem() {
        let app = launchFixture()
        element("navigation.item.settings", in: app).tap()
        let light = element("settings.appearance.light", in: app)
        let dark = element("settings.appearance.dark", in: app)
        XCTAssertTrue(light.waitForExistence(timeout: 3))
        light.tap()
        let lightImage = app.screenshot().pngRepresentation
        attachScreenshot(app, named: "Settings light appearance")
        dark.tap()
        let darkImage = app.screenshot().pngRepresentation
        attachScreenshot(app, named: "Settings dark appearance")
        XCTAssertNotEqual(lightImage, darkImage)
        element("settings.appearance.system", in: app).tap()
    }

    func testClosingLastWindowTerminatesTheApplication() {
        let app = launchFixture()

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixtures"] + arguments
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

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "UI - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
