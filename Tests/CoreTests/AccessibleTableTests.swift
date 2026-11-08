import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class AccessibleTableTests: XCTestCase {
    func testNumericSortUsesBytesAndPersistsWhenRowsAreReplaced() {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("memory", "Memory")])
        let large = AccessibleTableRow(
            id: "large",
            values: ["1.2 GB"],
            sortKeys: [.number(1_200_000_000)]
        )
        let small = AccessibleTableRow(
            id: "small",
            values: ["80 KB"],
            sortKeys: [.number(80_000)]
        )

        model.replaceRows([large, small], in: table)
        table.sortDescriptors = [NSSortDescriptor(key: "memory", ascending: true)]
        model.tableView(table, sortDescriptorsDidChange: [])

        XCTAssertEqual(model.rows.map(\.id), ["small", "large"])
        XCTAssertEqual(model.rows.first?.values.first, "80 KB")

        let updatedLarge = AccessibleTableRow(
            id: "large",
            values: ["1.5 GB"],
            sortKeys: [.number(1_500_000_000)]
        )
        let updatedSmall = AccessibleTableRow(
            id: "small",
            values: ["160 KB"],
            sortKeys: [.number(160_000)]
        )
        model.replaceRows([updatedLarge, updatedSmall], in: table)

        XCTAssertEqual(model.rows.map(\.id), ["small", "large"])
        XCTAssertEqual(model.rows.first?.values.first, "160 KB")
    }

    func testSelectionFollowsRowIdentityAcrossSortAndReplacementAndClearsWhenMissing() {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        let first = AccessibleTableRow(id: "first", values: ["Zulu"])
        let second = AccessibleTableRow(id: "second", values: ["Alpha"])
        var selectedID: String?
        model.onSelectionChanged = { selectedID = $0 }

        model.replaceRows([first, second], in: table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        model.tableViewSelectionDidChange(Notification(name: Notification.Name("selection"), object: table))
        XCTAssertEqual(selectedID, "first")

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        model.tableView(table, sortDescriptorsDidChange: [])
        XCTAssertEqual(model.rows.map(\.id), ["second", "first"])
        let selectedAfterSort = table.selectedRow
        XCTAssertTrue(model.rows.indices.contains(selectedAfterSort))
        if model.rows.indices.contains(selectedAfterSort) {
            XCTAssertEqual(model.rows[selectedAfterSort].id, "first")
        }

        model.replaceRows([second, first], in: table)
        let selectedAfterReplacement = table.selectedRow
        XCTAssertTrue(model.rows.indices.contains(selectedAfterReplacement))
        if model.rows.indices.contains(selectedAfterReplacement) {
            XCTAssertEqual(model.rows[selectedAfterReplacement].id, "first")
        }

        model.replaceRows([second], in: table)
        XCTAssertEqual(table.selectedRow, -1)
    }

    func testDefaultSortKeyOrdersTextColumns() {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        model.replaceRows([
            AccessibleTableRow(id: "zulu", values: ["Zulu"]),
            AccessibleTableRow(id: "alpha", values: ["Alpha"])
        ], in: table)

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        model.tableView(table, sortDescriptorsDidChange: [])

        XCTAssertEqual(model.rows.map(\.id), ["alpha", "zulu"])
    }

    func testUnchangedRowsAreNotReloadedAndChangedRowsReloadInPlace() {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name"), TableColumnSpec("cpu", "CPU", alignment: .right)])
        let rowsA = [
            AccessibleTableRow(id: "a", values: ["A", "1%"]),
            AccessibleTableRow(id: "b", values: ["B", "2%"]),
            AccessibleTableRow(id: "c", values: ["C", "3%"])
        ]
        model.replaceRows(rowsA, in: table)
        table.resetRecordedUpdates()

        model.replaceRows(rowsA, in: table)
        XCTAssertEqual(table.fullReloads, 0)
        XCTAssertTrue(table.partialReloads.isEmpty)
        XCTAssertTrue(table.insertedIndexes.isEmpty)
        XCTAssertTrue(table.removedIndexes.isEmpty)

        model.replaceRows([
            AccessibleTableRow(id: "a", values: ["A", "1%"]),
            AccessibleTableRow(id: "b", values: ["B", "9%"]),
            AccessibleTableRow(id: "c", values: ["C", "3%"])
        ], in: table)
        XCTAssertEqual(table.fullReloads, 0)
        XCTAssertEqual(table.partialReloads, [IndexSet(integer: 1)])
        XCTAssertTrue(table.insertedIndexes.isEmpty)
        XCTAssertTrue(table.removedIndexes.isEmpty)
        XCTAssertEqual(model.rows.map(\.values), [["A", "1%"], ["B", "9%"], ["C", "3%"]])
    }

    func testInsertAndRemoveUpdateRowsWithoutFullReloadAndKeepSelectionByIdentity() {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        model.replaceRows([
            AccessibleTableRow(id: "a", values: ["A"]),
            AccessibleTableRow(id: "b", values: ["B"]),
            AccessibleTableRow(id: "c", values: ["C"])
        ], in: table)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.resetRecordedUpdates()

        model.replaceRows([
            AccessibleTableRow(id: "b", values: ["B"]),
            AccessibleTableRow(id: "c", values: ["C"]),
            AccessibleTableRow(id: "d", values: ["D"])
        ], in: table)

        XCTAssertEqual(table.fullReloads, 0)
        XCTAssertEqual(table.removedIndexes, [IndexSet(integer: 0)])
        XCTAssertEqual(table.insertedIndexes, [IndexSet(integer: 2)])
        XCTAssertEqual(model.rows.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(table.selectedRow, 0)
    }

    func testReorderFallsBackToFullReload() {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        model.replaceRows([
            AccessibleTableRow(id: "zulu", values: ["Zulu"]),
            AccessibleTableRow(id: "alpha", values: ["Alpha"])
        ], in: table)
        table.resetRecordedUpdates()

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        model.tableView(table, sortDescriptorsDidChange: [])

        XCTAssertEqual(table.fullReloads, 1)
        XCTAssertEqual(model.rows.map(\.id), ["alpha", "zulu"])
    }

    func testRowViewsAreReusedAcrossRefreshes() {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        model.replaceRows([AccessibleTableRow(id: "a", values: ["A"])], in: table)
        let first = table.rowView(atRow: 0, makeIfNecessary: true)

        model.replaceRows([AccessibleTableRow(id: "a", values: ["A2"])], in: table)

        XCTAssertNotNil(first)
        XCTAssertTrue(table.rowView(atRow: 0, makeIfNecessary: false) === first)
        XCTAssertEqual(first?.accessibilityIdentifier(), "a")
    }

    func testColumnsHideAndShowWithoutChangingTheColumnSet() {
        let columns = [TableColumnSpec("name", "Name"), TableColumnSpec("cpu", "CPU", alignment: .right),
                       TableColumnSpec("gpu", "GPU", alignment: .right)]
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: columns)

        model.setColumnHidden("gpu", true)
        XCTAssertTrue(model.isColumnHidden("gpu"))
        XCTAssertEqual(model.visibleColumnKeys, ["name", "cpu"])
        XCTAssertEqual(table.tableColumns.map { $0.identifier.rawValue }, ["name", "cpu", "gpu"])

        model.setColumnHidden("gpu", false)
        XCTAssertFalse(model.isColumnHidden("gpu"))
        XCTAssertEqual(model.visibleColumnKeys, ["name", "cpu", "gpu"])
    }

    func testHeaderMenuTogglesColumnsAndNeverHidesTheLastVisibleOne() throws {
        let columns = [TableColumnSpec("name", "Name"), TableColumnSpec("cpu", "CPU", alignment: .right)]
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: columns)
        let menu = try XCTUnwrap(table.headerView?.menu)

        model.setColumnHidden("cpu", true)
        model.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Name", "CPU"])
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertFalse(menu.items[0].isEnabled, "the only visible column must stay visible")
        XCTAssertEqual(menu.items[1].state, .off)
        XCTAssertTrue(menu.items[1].isEnabled)

        _ = menu.items[1].target?.perform(menu.items[1].action, with: menu.items[1])
        XCTAssertFalse(model.isColumnHidden("cpu"))
    }

    func testNumericColumnsAlignHeaderAndCellsOnTheRight() throws {
        let columns = [TableColumnSpec("name", "Name"), TableColumnSpec("cpu", "CPU", alignment: .right)]
        let (table, _) = makeHostedTable()
        let autosave = "accessible-table-test.\(UUID().uuidString)"
        let model = AccessibleTableModel(table: table, columns: columns, autosaveName: autosave)
        model.replaceRows([AccessibleTableRow(id: "a", values: ["A", "4.2%"])], in: table)

        XCTAssertEqual(table.autosaveName, autosave)
        XCTAssertTrue(table.autosaveTableColumns)
        let cpuColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "cpu" })
        XCTAssertEqual(cpuColumn.headerCell.alignment, .right)
        let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: cpuColumn, row: 0))
        let field = try XCTUnwrap(textFields(in: cell).first)
        XCTAssertEqual(field.alignment, .right)
        XCTAssertEqual(field.stringValue, "4.2%")
    }

    func testEmptyStateOverlayFollowsRowCount() {
        let (table, scroll) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        model.configureEmptyState(symbolName: "magnifyingglass", title: "No processes match", caption: "Try another search.")
        let overlay = scroll.subviews.compactMap { $0 as? EmptyStateView }.first
        XCTAssertNotNil(overlay)
        XCTAssertEqual(overlay?.isHidden, false)

        model.replaceRows([AccessibleTableRow(id: "a", values: ["A"])], in: table)
        XCTAssertEqual(overlay?.isHidden, true)

        model.replaceRows([], in: table)
        XCTAssertEqual(overlay?.isHidden, false)
    }

    func testFirstColumnIconIsShownOnlyWhenTheModelReservesIt() throws {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let columns = [TableColumnSpec("name", "Name"), TableColumnSpec("cpu", "CPU", alignment: .right)]
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: columns, showsIconsInFirstColumn: true)
        model.replaceRows([AccessibleTableRow(id: "a", values: ["A", "1%"], icon: icon)], in: table)

        let nameColumn = try XCTUnwrap(table.tableColumns.first)
        let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: nameColumn, row: 0))
        let image = try XCTUnwrap(imageViews(in: cell).first)
        XCTAssertFalse(image.isHidden)
        XCTAssertTrue(image.image === icon)
    }

    func testFirstColumnBadgeIsAccessibleAndDoesNotChangeNameSorting() throws {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [TableColumnSpec("name", "Name")])
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        model.replaceRows([
            AccessibleTableRow(id: "zulu", values: ["zulu"], sortKeys: [.text("zulu")], badge: "You"),
            AccessibleTableRow(id: "alpha", values: ["alpha"], sortKeys: [.text("alpha")])
        ], in: table)

        XCTAssertEqual(model.rows.map(\.id), ["alpha", "zulu"])
        XCTAssertEqual(model.rows[1].values[0], "zulu")
        XCTAssertEqual(model.rows[1].badge, "You")
        let nameColumn = try XCTUnwrap(table.tableColumns.first)
        let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: nameColumn, row: 1))
        let badge = try XCTUnwrap(textFields(in: cell).first { $0.accessibilityIdentifier() == "zulu.name.badge" })
        XCTAssertEqual(badge.stringValue, "You")
    }

    func testRightAlignedValuesFillTheCellAndLeftAlignedValuesMeetTheLeadingInset() throws {
        let (table, _) = makeHostedTable()
        let model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("name", "Name", width: 200),
            TableColumnSpec("cpu", "CPU", width: 200, alignment: .right)
        ])
        // A short value: with intrinsic-width layout it would sit at the leading edge, far from the trailing inset.
        model.replaceRows([AccessibleTableRow(id: "a", values: ["A", "3"])], in: table)
        table.layoutSubtreeIfNeeded()

        let nameCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let cpuCell = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        nameCell.layoutSubtreeIfNeeded()
        cpuCell.layoutSubtreeIfNeeded()
        let nameLabel = try XCTUnwrap(textFields(in: nameCell).first { $0.accessibilityIdentifier() == "a.name" })
        let cpuLabel = try XCTUnwrap(textFields(in: cpuCell).first { $0.accessibilityIdentifier() == "a.cpu" })
        let nameFrame = nameLabel.convert(nameLabel.bounds, to: nameCell)
        let cpuFrame = cpuLabel.convert(cpuLabel.bounds, to: cpuCell)

        // A bezel-less label's frame extends about 2 pt beyond its drawn text on each side, so allow 3 pt.
        XCTAssertEqual(cpuLabel.alignment, .right)
        XCTAssertEqual(cpuFrame.maxX, cpuCell.bounds.width - 8, accuracy: 3,
                       "a right-aligned value must end at the trailing inset, under its right-aligned header")
        XCTAssertGreaterThanOrEqual(cpuFrame.width, cpuCell.bounds.width - 8 - 8 - 4,
                                    "a right-aligned value must fill the cell so its text reaches the trailing edge")
        XCTAssertEqual(nameFrame.minX, 8, accuracy: 3,
                       "a left-aligned value must start at the leading inset")
    }

    private func makeHostedTable() -> (RecordingTableView, NSScrollView) {
        let table = RecordingTableView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.layoutSubtreeIfNeeded()
        return (table, scroll)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        for subview in view.subviews { found += textFields(in: subview) }
        return found
    }

    private func imageViews(in view: NSView) -> [NSImageView] {
        var found: [NSImageView] = []
        if let image = view as? NSImageView { found.append(image) }
        for subview in view.subviews { found += imageViews(in: subview) }
        return found
    }
}

/// Records the table mutations the model issues so tests can assert on diffing.
@MainActor
private final class RecordingTableView: NSTableView {
    private(set) var fullReloads = 0
    private(set) var partialReloads: [IndexSet] = []
    private(set) var insertedIndexes: [IndexSet] = []
    private(set) var removedIndexes: [IndexSet] = []

    func resetRecordedUpdates() {
        fullReloads = 0
        partialReloads = []
        insertedIndexes = []
        removedIndexes = []
    }

    override func reloadData() {
        fullReloads += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        partialReloads.append(rowIndexes)
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func insertRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        insertedIndexes.append(indexes)
        super.insertRows(at: indexes, withAnimation: animationOptions)
    }

    override func removeRows(at indexes: IndexSet, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        removedIndexes.append(indexes)
        super.removeRows(at: indexes, withAnimation: animationOptions)
    }
}
