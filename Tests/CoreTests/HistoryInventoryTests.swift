import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class HistoryInventoryTests: XCTestCase {
    // MARK: Inventory

    func testKindLabelsAreHumanReadable() {
        XCTAssertEqual(InventoryLabels.kind(.loginItem), "Login Item")
        XCTAssertEqual(InventoryLabels.kind(.launchAgent), "Launch Agent")
        XCTAssertEqual(InventoryLabels.kind(.launchDaemon), "Launch Daemon")
        XCTAssertEqual(InventoryLabels.kind(.service), "Service")
    }

    func testStatusLabelsAndDotTonesFollowTheStatusColumnContract() {
        XCTAssertEqual(InventoryLabels.status(.running).label, "Running")
        XCTAssertEqual(InventoryLabels.status(.running).tone, .positive)
        XCTAssertEqual(InventoryLabels.status(.loaded).label, "Loaded")
        XCTAssertEqual(InventoryLabels.status(.loaded).tone, .positive)
        XCTAssertEqual(InventoryLabels.status(.stopped).label, "Stopped")
        XCTAssertEqual(InventoryLabels.status(.stopped).tone, .caution)
        XCTAssertEqual(InventoryLabels.status(.unknown).label, "Unknown")
        XCTAssertEqual(InventoryLabels.status(.unknown).tone, .neutral)
    }

    func testInventoryRowsKeepCollidingSlugsDistinctAndMissingPathsUnavailable() {
        let entries = [
            entry(id: "agent-a", name: "Agent", path: nil, state: .unknown),
            entry(id: "agent_a", name: "Agent Two", path: "/Applications/Foo.app/Contents/MacOS/foo", state: .stopped),
            entry(id: "tool", name: "Tool", path: "/usr/local/bin/tool", state: .running)
        ]
        let rows = InventoryRows.rows(for: entries, pageIdentifier: "startup")

        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        let first = try! XCTUnwrap(rows.first { $0.entry.id == "agent-a" })
        XCTAssertEqual(first.id, "startup.item.agent-a.entry.agent-a")
        XCTAssertNil(first.path)
        XCTAssertEqual(first.text(.path), "Path unavailable")
        XCTAssertNil(first.iconBundlePath)

        let app = try! XCTUnwrap(rows.first { $0.entry.id == "agent_a" })
        XCTAssertEqual(app.iconBundlePath, "/Applications/Foo.app")
        XCTAssertEqual(app.tone, .caution)

        let tool = try! XCTUnwrap(rows.first { $0.entry.id == "tool" })
        XCTAssertEqual(tool.id, "startup.item.tool")
        XCTAssertNil(tool.iconBundlePath)
        XCTAssertEqual(tool.owner, "Unavailable")
    }

    func testInventoryRowsDefaultToNameOrderAndSortByDisplayText() {
        let rows = InventoryRows.rows(for: [
            entry(id: "b", name: "Beta", path: "/b", state: .running),
            entry(id: "a", name: "alpha", path: "/a", state: .stopped),
            entry(id: "c", name: "Gamma", path: nil, state: .unknown)
        ], pageIdentifier: "services")

        XCTAssertEqual(rows.map(\.name), ["alpha", "Beta", "Gamma"])
        XCTAssertEqual(InventoryRows.ordered(rows, by: .name, ascending: false).map(\.name), ["Gamma", "Beta", "alpha"])
        XCTAssertEqual(InventoryRows.ordered(rows, by: .state, ascending: true).map(\.status), ["Running", "Stopped", "Unknown"])
        XCTAssertEqual(InventoryRows.ordered(rows, by: nil, ascending: true).map(\.name), rows.map(\.name))
    }

    // MARK: App History builder

    func testHistoryWindowIsInclusiveUTCAndDaysAreNewestFirst() {
        let summaries = [
            summary(day: "2026-04-01", app: "app-a", name: "A", cpu: 1),
            summary(day: "2026-04-02", app: "app-a", name: "A", cpu: 2),
            summary(day: "2026-05-01", app: "app-a", name: "A", cpu: 3),
            summary(day: "2026-05-02", app: "app-b", name: "B", cpu: 4)
        ]
        let result = AppHistoryBuilder.summarize(summaries, through: date("2026-05-01T19:00:00Z"))

        XCTAssertEqual(result.groups.count, 1)
        let group = result.groups[0]
        XCTAssertEqual(group.total.title, "A")
        XCTAssertEqual(group.days.map(\.title), ["2026-05-01", "2026-04-02"])
        XCTAssertEqual(group.days[0].id, "history.day.2026-05-01.a")
    }

    func testGapDaysUseGapIdentifiersAndCollidingNamesGetApplicationSuffix() {
        let summaries = [
            summary(day: "2026-05-01", app: "editor-1", name: "Editor", cpu: 5, gaps: 1),
            summary(day: "2026-05-01", app: "editor-2", name: "Editor", cpu: 6)
        ]
        let result = AppHistoryBuilder.summarize(summaries, through: date("2026-05-01T12:00:00Z"))

        // Both names are "Editor", so their order is not defined; compare as a set.
        XCTAssertEqual(Set(result.groups.map(\.total.id)), [
            "history.total.editor.application.editor-1",
            "history.total.editor.application.editor-2"
        ])
        let gapGroup = try! XCTUnwrap(result.groups.first { $0.total.id.hasSuffix("editor-1") })
        XCTAssertEqual(gapGroup.days.first?.id, "history.gap.2026-05-01.editor.application.editor-1")
        XCTAssertEqual(result.gaps, 1)
        XCTAssertEqual(result.counterResets, 0)
    }

    func testMissingValuesStayUnavailableAndPartialTotalsAreMarked() {
        let unmeasured = AppHistoryBuilder.totalText([nil, nil], unit: .bytes, gapCount: 0)
        XCTAssertEqual(unmeasured, AppHistoryCellText(display: "Unavailable", detail: nil))

        let unmeasuredWithGaps = AppHistoryBuilder.totalText([nil, nil], unit: .bytes, gapCount: 2)
        XCTAssertEqual(unmeasuredWithGaps, AppHistoryCellText(display: "Unavailable", detail: "No measured value; 2 gap(s)"))

        let partial = AppHistoryBuilder.totalText([1_024, nil], unit: .bytes, gapCount: 0)
        XCTAssertTrue(partial.display.hasPrefix("≥ "), partial.display)
        XCTAssertFalse(partial.display.contains("partial"))
        XCTAssertEqual(partial.detail?.hasPrefix("Measured "), true)
        XCTAssertEqual(partial.detail?.contains("partial"), true)
        XCTAssertEqual(partial.detail?.contains("1 day(s) not measured"), true)

        let complete = AppHistoryBuilder.totalText([1_024, 2_048], unit: .bytes, gapCount: 0)
        XCTAssertFalse(complete.display.hasPrefix("≥"))
        XCTAssertFalse(complete.display.contains("partial"))
        XCTAssertNil(complete.detail)

        XCTAssertEqual(AppHistoryBuilder.dailyText(nil, unit: .seconds, gaps: 1),
                       AppHistoryCellText(display: "Missing", detail: "No measured value; 1 gap(s)"))
        XCTAssertEqual(AppHistoryBuilder.dailyText(nil, unit: .seconds, gaps: 0),
                       AppHistoryCellText(display: "Unavailable", detail: nil))
        let partialDay = AppHistoryBuilder.dailyText(108, unit: .seconds, gaps: 1)
        XCTAssertTrue(partialDay.display.hasPrefix("≥ "), partialDay.display)
        XCTAssertEqual(partialDay.detail?.contains("partial"), true)
        XCTAssertNil(AppHistoryBuilder.sumOfMeasured([nil, nil]))
        XCTAssertEqual(AppHistoryBuilder.sumOfMeasured([1, nil, 2]), 3)
    }

    func testPartialTotalKeepsTheNumberVisibleAndExplainsItInTooltipAndAccessibility() {
        let text = AppHistoryBuilder.totalText([108], unit: .seconds, gapCount: 1)
        let number = UIFormat.metric(MetricReading(value: 108, unit: .seconds, timestamp: .distantPast))
        XCTAssertEqual(number, "108.0 s")
        XCTAssertEqual(text.display, "≥ 108.0 s")

        let detail = try! XCTUnwrap(text.detail)
        XCTAssertEqual(detail, "Measured 108.0 s; partial — 1 gap(s); actual total may be higher")
        XCTAssertFalse(text.display.contains("Measured"))
        XCTAssertFalse(text.display.contains("·"))

        // Partial day rows follow the same rule.
        let day = AppHistoryBuilder.dailyText(108, unit: .seconds, gaps: 1)
        XCTAssertEqual(day.display, "≥ 108.0 s")
        XCTAssertEqual(day.detail, "Measured 108.0 s; partial — 1 gap(s) on this day; actual value may be higher")

        // Row wiring: the detail is exposed per column and the visible text stays the compact form.
        let appRow = AppHistoryRow(
            id: "history.total.editor",
            values: ["Editor", text.display, "", "", "", "", "1 / 1 / 0"],
            details: [nil, text.detail, nil, nil, nil, nil, nil],
            numbers: [nil, 108, nil, nil, nil, nil, 1]
        )
        XCTAssertEqual(appRow.detail(.cpu), detail)
        XCTAssertNil(appRow.detail(.application))
    }

    func testPartialTotalsFitTheCpuColumnAtTheCellFont() {
        let column = AppHistoryColumn.cpu
        let available = column.width - AppHistoryColumn.cellLeadingInset - AppHistoryColumn.cellTrailingInset
        let samples: [(Double, MetricUnit)] = [(0.5, .seconds), (108, .seconds), (9_999.9, .seconds), (999.9, .seconds)]
        for (value, unit) in samples {
            let text = AppHistoryBuilder.totalText([value], unit: unit, gapCount: 1).display
            let width = NSAttributedString(string: text, attributes: [.font: column.cellFont]).size().width
            XCTAssertLessThanOrEqual(width, available, "\"\(text)\" needs \(width)pt, column allows \(available)pt")
        }
        let worst = AppHistoryBuilder.totalText([9_999.9], unit: .seconds, gapCount: 1).display
        let worstNumber = UIFormat.metric(MetricReading(value: 9_999.9, unit: .seconds, timestamp: .distantPast))
        XCTAssertEqual(worst, "≥ \(worstNumber)")
    }

    func testNumericHistoryCellsMeetTheTrailingInsetUnderTheirRightAlignedHeader() throws {
        let values = ["Safari", "≥ 108.0 s", "1 MB", "2 MB", "3 MB", "4 MB", "2 samples"]
        let total = AppHistoryRow(id: "history.total.safari", values: values,
                                  numbers: [nil, 108, 1, 2, 3, 4, 2])
        let group = AppHistoryGroup(total: total, executablePath: nil, days: [])
        let controller = AppHistoryOutlineController(autosaveName: nil)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        controller.update(groups: [group])
        controller.scrollView.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(controller.scrollView.documentView as? NSOutlineView)
        let cpuIndex = try XCTUnwrap(outline.tableColumns.firstIndex { $0.identifier.rawValue == AppHistoryColumn.cpu.rawValue })
        let cell = try XCTUnwrap(outline.view(atColumn: cpuIndex, row: 0, makeIfNecessary: true) as? NSTableCellView)
        cell.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(textFields(in: cell).first { $0.accessibilityIdentifier() == "history.total.safari.cpu" })
        let labelFrame = label.convert(label.bounds, to: cell)

        XCTAssertEqual(label.stringValue, "≥ 108.0 s")
        XCTAssertEqual(label.alignment, .right)
        // A bezel-less label's frame extends about 2 pt beyond its drawn text on each side, so allow 3 pt.
        XCTAssertEqual(labelFrame.maxX, cell.bounds.width - AppHistoryColumn.cellTrailingInset, accuracy: 3,
                       "a numeric value must end at the trailing inset, under its right-aligned header")
        XCTAssertGreaterThanOrEqual(labelFrame.width,
                                    cell.bounds.width - AppHistoryColumn.cellLeadingInset - AppHistoryColumn.cellTrailingInset - 4,
                                    "a numeric value must fill the cell so its text reaches the trailing edge")
    }

    func testSortingUsesNumericValuesAndSendsUnavailableLast() {
        let rows = [
            row(id: "nine", title: "Nine", cpu: 9),
            row(id: "missing", title: "Missing", cpu: nil),
            row(id: "ten", title: "Ten", cpu: 10)
        ]
        let ascending = AppHistorySort.ordered(rows, row: { $0 }, by: AppHistorySortOrder(column: .cpu, ascending: true))
        XCTAssertEqual(ascending.map(\.id), ["nine", "ten", "missing"])

        let descending = AppHistorySort.ordered(rows, row: { $0 }, by: AppHistorySortOrder(column: .cpu, ascending: false))
        XCTAssertEqual(descending.map(\.id), ["ten", "nine", "missing"])

        let byName = AppHistorySort.ordered(rows, row: { $0 }, by: AppHistorySortOrder(column: .application, ascending: true))
        XCTAssertEqual(byName.map(\.id), ["missing", "nine", "ten"])
    }

    func testSortOrderReadsTheHeaderKeyAndDirection() {
        let order = AppHistorySortOrder(descriptor: NSSortDescriptor(key: "cpu", ascending: false))
        XCTAssertEqual(order?.column, .cpu)
        XCTAssertEqual(order?.ascending, false)
        XCTAssertNil(AppHistorySortOrder(descriptor: NSSortDescriptor(key: "unknown", ascending: true)))
        XCTAssertNil(AppHistorySortOrder(descriptor: nil))
    }

    // MARK: App History status

    func testBannerPrefersFailureThenGapsThenInformation() {
        let failed = AppHistoryStatus.banner(
            availability: MetricAvailability(available: false, reason: .collectionFailed, detail: "disk full"),
            applicationCount: 2, gaps: 3, counterResets: 0, timestamp: date("2026-05-01T12:00:00Z")
        )
        XCTAssertEqual(failed.style, .error)
        XCTAssertTrue(failed.text.contains("disk full"))

        let gapped = AppHistoryStatus.banner(availability: nil, applicationCount: 2, gaps: 1, counterResets: 1,
                                             timestamp: date("2026-05-01T12:00:00Z"))
        XCTAssertEqual(gapped.style, .warning)
        XCTAssertTrue(gapped.text.contains("1 gap(s)"))

        let empty = AppHistoryStatus.banner(availability: nil, applicationCount: 0, gaps: 0, counterResets: 0,
                                            timestamp: date("2026-05-01T12:00:00Z"))
        XCTAssertEqual(empty.style, .info)
        XCTAssertEqual(empty.text, "No application history recorded yet.")
    }

    // MARK: Helpers

    private func entry(id: String, name: String, path: String?, state: DiscoveredEntryState) -> DiscoveredEntrySnapshot {
        DiscoveredEntrySnapshot(id: id, kind: .launchAgent, name: name, path: path, ownerUID: nil, state: state)
    }

    private func summary(day: String, app: String, name: String, cpu: Double,
                         gaps: Int = 0, resets: Int = 0) -> ApplicationDailyHistorySummary {
        ApplicationDailyHistorySummary(
            dayStart: date("\(day)T00:00:00Z"),
            application: ApplicationHistoryIdentity(id: app, name: name, executablePath: nil, association: .standalone),
            cpuSeconds: cpu, diskReadBytes: nil, diskWriteBytes: nil,
            networkReceiveBytes: nil, networkTransmitBytes: nil,
            sampleCount: 3, gaps: gaps, counterResets: resets
        )
    }

    private func row(id: String, title: String, cpu: Double?) -> AppHistoryRow {
        AppHistoryRow(id: id, values: [title, "", "", "", "", "", ""], numbers: [nil, cpu, nil, nil, nil, nil, nil])
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
    }
}
