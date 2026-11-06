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
}
