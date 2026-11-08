import XCTest
import AppKit

@MainActor
final class MicrogravityUITests: XCTestCase {
    private var fixtureDefaultsSuite = ""
    private var launchedApplications: [XCUIApplication] = []

    override func setUp() {
        super.setUp()
        let methodName = name.split(whereSeparator: \.isWhitespace).last ?? "unknown"
        let safeMethodName = methodName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        fixtureDefaultsSuite = "Microgravity.UITests.\(safeMethodName)"
    }

    override func tearDown() {
        terminateLaunchedApplications()
        launchedApplications.removeAll()
        super.tearDown()
    }

    func testProcessesExpandSearchSortAndKeepSelectionIdentity() {
        let app = launchFixture()

        XCTAssertTrue(element("process.table", in: app).waitForExistence(timeout: 5))
        let group = row("process.group.fixture-editor", in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        let disclosure = groupDisclosure("process.group.fixture-editor", in: app)
        XCTAssertEqual((disclosure.value as? NSNumber)?.intValue, 0,
                       "Fixture process groups must start collapsed.")
        expandGroup("process.group.fixture-editor", in: app)

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
        clickColumnHeader(cpuHeader, headerView: element("process.table.header", in: app))
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
        attachScreenshot(app, named: "Processes")
    }

    func testDuplicateGroupTitlesExpandTheClickedGroup() {
        let app = launchFixture(arguments: ["--ui-test-duplicate-groups"])
        let firstGroup = row("process.group.fixture-editor.pid-410-start-1700000001-10000", in: "process.table", app: app)
        let secondGroup = row("process.group.fixture-editor.pid-620-start-1700000003-30000", in: "process.table", app: app)
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(secondGroup.waitForExistence(timeout: 3))
        expandGroup("process.group.fixture-editor.pid-620-start-1700000003-30000", in: app)
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
        let disclosure = groupDisclosure(groupID, in: app)
        XCTAssertEqual((disclosure.value as? NSNumber)?.intValue, 0,
                       "A new fixture launch must start collapsed before the persistence interaction.")
        expandGroup(groupID, in: app)
        let child = row("process.row.410", in: "process.table", app: app)
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        XCTAssertTrue(child.isHittable)
        XCTAssertEqual((disclosure.value as? NSNumber)?.intValue, 1)

        app.launchArguments.removeAll { $0 == "--ui-test-reset-expansion-state" }
        app.terminate()
        app.launch()
        XCTAssertTrue(element("navigation.item.processes", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).waitForExistence(timeout: 3))
        XCTAssertEqual((groupDisclosure(groupID, in: app).value as? NSNumber)?.intValue, 1,
                       "A fresh app process should restore the expanded identity.")
    }

    func testSelectionSurvivesSnapshotRefresh() {
        let app = launchFixture(arguments: ["--ui-test-refresh-pulse"])
        let child = row("process.row.410", in: "process.table", app: app)
        expandGroup("process.group.fixture-editor", in: app)
        XCTAssertTrue(child.waitForExistence(timeout: 3), "Expanded group must expose its child row.")
        XCTAssertTrue(child.isHittable, "Expanded child row must be visible for selection.")
        let process = child
        process.click()
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
        expandGroup("process.group.fixture-editor", in: app)
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
        expandGroup("process.group.fixture-editor", in: app)
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

        expandGroup("process.group.fixture-editor", in: app)
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

    func testForceQuitCancelPreservesSelectedProcess() {
        let app = launchFixture()
        expandGroup("process.group.fixture-editor", in: app)
        let process = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(process.waitForExistence(timeout: 3))
        process.click()
        let selectedIdentity = app.staticTexts["process.selection.identity"].label
        XCTAssertTrue(selectedIdentity.contains("pid=411"))

        element("process.action.force-quit", in: app).click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].click()

        XCTAssertTrue(app.staticTexts["process.selection.identity"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
        XCTAssertTrue(row("process.row.411", in: "process.table", app: app).exists)
        XCTAssertTrue(element("process.action.force-quit", in: app).isEnabled)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testForceQuitConfirmationRunsOnlyExpectedFixtureIdentity() {
        let app = launchFixture(arguments: ["--ui-test-successful-force-quit"])
        expandGroup("process.group.fixture-editor", in: app)
        let process = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(process.waitForExistence(timeout: 3))
        process.click()
        XCTAssertTrue(app.staticTexts["process.selection.identity"].label.contains("pid=411"))

        element("process.action.force-quit", in: app).click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        let targetDescription = confirmation.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "(process 411)")
        ).firstMatch
        XCTAssertTrue(targetDescription.waitForExistence(timeout: 3),
                      "Force Quit sheet must name process 411 in its informative text: \(confirmation.debugDescription)")
        let targetValue = targetDescription.value as? String
        XCTAssertTrue(targetValue?.contains("(process 411)") == true,
                      "Unexpected Force Quit target description: \(String(describing: targetValue))")
        element("process.force-quit.confirm", in: app).click()

        XCTAssertFalse(row("process.row.411", in: "process.table", app: app).waitForExistence(timeout: 3))
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).exists)
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, "No process selected")
        XCTAssertFalse(app.sheets.firstMatch.exists)
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
        let editorCPU = app.staticTexts["history.total.fixture-editor.cpu"].label
        let indexerCPU = app.staticTexts["history.total.fixture-indexer.cpu"].label

        element("navigation.item.processes", in: app).click()
        expandGroup("process.group.fixture-editor", in: app)
        let selectedProcess = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(selectedProcess.waitForExistence(timeout: 3))
        selectedProcess.click()
        let selectedIdentity = app.staticTexts["process.selection.identity"].label
        XCTAssertTrue(selectedIdentity.contains("pid=411"))
        element("navigation.item.history", in: app).click()

        element("history.action.reset", in: app).click()
        // Reset confirmation is an NSAlert presented as a sheet on the window (U14); it may surface as a sheet or an alert.
        let confirmation = app.sheets.firstMatch.waitForExistence(timeout: 3)
            ? app.sheets.firstMatch
            : app.alerts["Reset App History"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).exists)
        XCTAssertEqual(app.staticTexts["history.total.fixture-editor.cpu"].label, editorCPU)
        XCTAssertEqual(app.staticTexts["history.total.fixture-indexer.cpu"].label, indexerCPU)
        XCTAssertTrue(gap.exists)
        attachScreenshot(app, named: "App History")

        element("navigation.item.processes", in: app).click()
        XCTAssertTrue(row("process.row.411", in: "process.table", app: app).exists)
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
    }

    func testConfirmHistoryResetClearsHistoryWithoutChangingProcesses() {
        let app = launchFixture(arguments: ["--ui-test-history-gap"])
        expandGroup("process.group.fixture-editor", in: app)
        let selectedProcess = row("process.row.411", in: "process.table", app: app)
        XCTAssertTrue(selectedProcess.waitForExistence(timeout: 3))
        selectedProcess.click()
        let selectedIdentity = app.staticTexts["process.selection.identity"].label
        XCTAssertTrue(selectedIdentity.contains("pid=411"))

        element("navigation.item.history", in: app).click()
        XCTAssertTrue(element("history.total.fixture-editor.application", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("history.total.fixture-indexer.application", in: app).exists)
        element("history.action.reset", in: app).click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Reset History"].click()

        XCTAssertFalse(element("history.total.fixture-editor.application", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("history.total.fixture-indexer.application", in: app).exists)
        XCTAssertTrue(app.staticTexts["No app history yet"].waitForExistence(timeout: 3))

        element("navigation.item.processes", in: app).click()
        XCTAssertTrue(row("process.row.410", in: "process.table", app: app).exists)
        XCTAssertTrue(row("process.row.411", in: "process.table", app: app).exists)
        XCTAssertEqual(app.staticTexts["process.selection.identity"].label, selectedIdentity)
    }

    func testHistorySortsFormattedTotalsByNumericValues() {
        let app = launchFixture()
        element("navigation.item.history", in: app).click()

        let editor = app.staticTexts["history.total.fixture-editor.application"]
        let indexer = app.staticTexts["history.total.fixture-indexer.application"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(indexer.waitForExistence(timeout: 3))
        let editorCPU = app.staticTexts["history.total.fixture-editor.cpu"]
        let indexerCPU = app.staticTexts["history.total.fixture-indexer.cpu"]
        XCTAssertTrue(editorCPU.exists)
        XCTAssertTrue(indexerCPU.exists)
        let headerView = element("history.table.header", in: app)
        XCTAssertTrue(headerView.exists)
        XCTAssertLessThan(headerView.frame.maxY, editor.frame.minY)
        // Fixture source values are 108 seconds for Editor and 18 seconds for Indexer.
        // The unsorted builder order is alphabetical.
        XCTAssertLessThan(editor.frame.minY, indexer.frame.minY)

        let cpuHeader = app.descendants(matching: .any).matching(identifier: "cpu").firstMatch
        XCTAssertTrue(cpuHeader.exists)
        clickColumnHeader(cpuHeader, headerView: headerView)
        XCTAssertLessThan(indexer.frame.minY, editor.frame.minY,
                          "Ascending numeric CPU sort must put 18-second Indexer before 108-second Editor.")

        clickColumnHeader(cpuHeader, headerView: headerView)
        XCTAssertLessThan(editor.frame.minY, indexer.frame.minY,
                          "Descending numeric CPU sort must put 108-second Editor before 18-second Indexer.")
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
        let lightImage = windowScreenshot(in: app).pngRepresentation
        attachScreenshot(app, named: "Settings light appearance")
        choosePopUpItem("settings.appearance.dark", in: "settings.appearance", app: app)
        let darkImage = windowScreenshot(in: app).pngRepresentation
        attachScreenshot(app, named: "Settings dark appearance")
        XCTAssertNotEqual(lightImage, darkImage)
        choosePopUpItem("settings.appearance.system", in: "settings.appearance", app: app)
    }

    func testVisualAcceptanceCapturesAllPagesAtBothSizesAndAppearances() {
        let app = launchFixture(arguments: ["--ui-test-visual-captures"])
        let window = app.windows.matching(identifier: "ui-test.visual-window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard window.frame.size == CGSize(width: 1280, height: 820) else {
            XCTFail("A clean fixture launch must open at 1280x820 points; measured window frame \(window.frame).")
            return
        }

        let pages: [(name: String, navigation: String, content: String)] = [
            ("Processes", "navigation.item.processes", "process.table"),
            ("Performance", "navigation.item.performance", "performance.graph.cpu-total"),
            ("AppHistory", "navigation.item.history", "history.table"),
            ("Startup", "navigation.item.startup", "startup.table"),
            ("Users", "navigation.item.users", "users.table"),
            ("Details", "navigation.item.details", "details.table"),
            ("Services", "navigation.item.services", "services.table"),
            ("Settings", "navigation.item.settings", "settings.appearance")
        ]
        let appearances = ["system", "light", "dark"]
        let sizes: [(name: String, width: Int, height: Int)] = [
            ("default", 1280, 820),
            ("minimum", 960, 600)
        ]
        var manifest = ["page,requestedAppearance,selectedAppearance,windowFramePoints,screenshotPixels,screenshotAttachment"]

        for size in sizes {
            if size.name == "minimum" {
                resizeWindow(window, toWindowSize: CGSize(width: size.width, height: size.height))
            }

            for requestedAppearance in appearances {
                element("navigation.item.settings", in: app).click()
                guard window.frame.size == CGSize(width: size.width, height: size.height) else {
                    XCTFail("Opening Settings changed window frame to \(window.frame); expected \(size.width)x\(size.height).")
                    return
                }
                choosePopUpItem("settings.appearance.\(requestedAppearance)",
                                in: "settings.appearance", app: app)
                guard window.frame.size == CGSize(width: size.width, height: size.height) else {
                    XCTFail("Selecting \(requestedAppearance) appearance changed window frame to \(window.frame); expected \(size.width)x\(size.height).")
                    return
                }
                let appearancePicker = app.popUpButtons.matching(identifier: "settings.appearance").firstMatch
                let selectedAppearance = appearancePicker.value as? String
                let expectedAppearance = requestedAppearance.capitalized
                guard selectedAppearance?.localizedCaseInsensitiveContains(expectedAppearance) == true else {
                    XCTFail("Expected native Appearance menu to select \(expectedAppearance); measured \(String(describing: selectedAppearance)).")
                    return
                }

                for page in pages {
                    element(page.navigation, in: app).click()
                    XCTAssertTrue(element(page.content, in: app).waitForExistence(timeout: 5), page.name)
                    let frame = window.frame
                    guard frame.size == CGSize(width: size.width, height: size.height) else {
                        XCTFail("Expected \(page.name) window at \(size.width)x\(size.height) points; measured frame \(frame).")
                        return
                    }

                    let attachmentName = "Visual-\(size.name)-\(requestedAppearance)-\(page.name)-\(size.width)x\(size.height)"
                    let pixelSize = attachScreenshot(window, named: attachmentName)
                    manifest.append("\(page.name),\(requestedAppearance),\(selectedAppearance ?? "unknown"),\(Int(frame.width.rounded()))x\(Int(frame.height.rounded())),\(pixelSize.width)x\(pixelSize.height),\(attachmentName)")
                }
            }
        }

        XCTAssertEqual(manifest.count - 1, 48)
        let attachment = XCTAttachment(data: Data(manifest.joined(separator: "\n").utf8),
                                       uniformTypeIdentifier: "public.plain-text")
        attachment.name = "Visual acceptance capture manifest"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testClosingLastWindowTerminatesTheApplication() {
        let app = launchFixture()

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        launchedApplications.append(app)
        app.launchArguments = ["--ui-test-fixtures", "--ui-test-reset-expansion-state"] + arguments
        app.launchEnvironment["MICROGRAVITY_UI_TEST_DEFAULTS_SUITE"] = fixtureDefaultsSuite
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

    private func groupDisclosure(_ groupIdentifier: String, in app: XCUIApplication) -> XCUIElement {
        let group = row(groupIdentifier, in: "process.table", app: app)
        XCTAssertTrue(group.waitForExistence(timeout: 3), groupIdentifier)
        let disclosure = group.descendants(matching: .disclosureTriangle).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3), groupIdentifier)
        return disclosure
    }

    private func expandGroup(_ groupIdentifier: String, in app: XCUIApplication) {
        let disclosure = groupDisclosure(groupIdentifier, in: app)
        guard let value = disclosure.value as? NSNumber else {
            XCTFail("The native group disclosure must expose its expanded state: \(groupIdentifier)")
            return
        }
        if !value.boolValue { disclosure.click() }
        let expanded = expectation(for: NSPredicate(format: "value == %@", NSNumber(value: true)),
                                   evaluatedWith: disclosure)
        wait(for: [expanded], timeout: 3)
    }

    private func clickColumnHeader(_ column: XCUIElement, headerView: XCUIElement) {
        XCTAssertTrue(column.exists)
        XCTAssertTrue(headerView.exists)
        let columnFrame = column.frame
        let headerFrame = headerView.frame
        XCTAssertGreaterThan(headerFrame.width, 0)
        XCTAssertGreaterThan(headerFrame.height, 0)
        let normalizedColumnCenter = (columnFrame.midX - headerFrame.minX) / headerFrame.width
        XCTAssertGreaterThanOrEqual(normalizedColumnCenter, 0)
        XCTAssertLessThanOrEqual(normalizedColumnCenter, 1)
        headerView.coordinate(withNormalizedOffset: CGVector(dx: normalizedColumnCenter, dy: 0.5)).click()
    }

    private func terminateLaunchedApplications() {
        for app in launchedApplications.reversed() where app.state != .notRunning {
            app.activate()
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                          "Fixture app must quit cleanly and clear its test preferences.")
        }
    }

    private func resizeWindow(_ window: XCUIElement, toWindowSize size: CGSize) {
        let initialFrame = window.frame
        guard initialFrame.size == CGSize(width: 1280, height: 820) else {
            XCTFail("Resize must start from a measured 1280x820 window frame; measured \(initialFrame).")
            return
        }

        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.999))
        let destination = start.withOffset(CGVector(dx: size.width - 1280, dy: size.height - 820))
        start.press(forDuration: 0.1, thenDragTo: destination)
        let expected = size
        let resized = expectation(for: NSPredicate { object, _ in
            guard let window = object as? XCUIElement else { return false }
            return window.frame.size == expected
        }, evaluatedWith: window)
        wait(for: [resized], timeout: 5)
        XCTAssertEqual(window.frame.size, expected)
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
        let attachment = XCTAttachment(screenshot: windowScreenshot(in: app))
        attachment.name = "UI - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(_ window: XCUIElement, named name: String) -> (width: Int, height: Int) {
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "UI - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else {
            XCTFail("Could not decode PNG for \(name).")
            return (0, 0)
        }
        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func windowScreenshot(in app: XCUIApplication) -> XCUIScreenshot {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Expected a window screenshot for \(name).")
        return window.screenshot()
    }
}
