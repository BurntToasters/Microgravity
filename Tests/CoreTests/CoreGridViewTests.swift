import AppKit
import XCTest
@testable import Microgravity

/// Tile geometry for `CoreGridView`. Every tile is placed from the grid's current width, so a resize, a
/// hidden-to-shown change, an appearance change, or a core-count change must leave each tile inside the grid,
/// in a non-overlapping row and column that matches `columns(for:)`.
@MainActor
final class CoreGridViewTests: XCTestCase {
    private static let tileHeight: CGFloat = 76
    private static let gap: CGFloat = 10

    func testTilesStayInsideNonOverlappingRowsAtEachWidth() throws {
        let host = Host()
        host.grid.update(cores: Self.cores(18), mapping: .index(capacity: 60))
        for width: CGFloat in [500, 900, 1200, 500] {
            host.resize(to: width)
            try assertTileGeometry(host.grid, coreCount: 18)
        }
    }

    func testTilesAreRepositionedAfterHiddenThenShownAtAnotherWidth() throws {
        let host = Host()
        host.grid.update(cores: Self.cores(18), mapping: .index(capacity: 60))
        host.resize(to: 900)
        try assertTileGeometry(host.grid, coreCount: 18)

        host.grid.isHidden = true
        host.resize(to: 1200)
        host.grid.isHidden = false
        host.resize(to: 500)
        try assertTileGeometry(host.grid, coreCount: 18)

        host.grid.isHidden = true
        host.resize(to: 1200)
        host.grid.isHidden = false
        host.window.appearance = NSAppearance(named: .darkAqua)
        host.resize(to: 1200)
        try assertTileGeometry(host.grid, coreCount: 18)
        host.window.appearance = NSAppearance(named: .aqua)
    }

    func testTilesFollowCoreCountChangesAtAFixedWidth() throws {
        let host = Host()
        host.resize(to: 900)
        for count in [18, 12, 5, 18, 0, 7] {
            host.grid.update(cores: Self.cores(count), mapping: .index(capacity: 60))
            host.resize(to: 900)
            try assertTileGeometry(host.grid, coreCount: count)
        }
    }

    func testSectionHeadersSitAboveTheirTilesInsideTheirOwnBandAtEachWidth() throws {
        let host = Host()
        host.grid.update(sections: Self.groupedSections(), mapping: .index(capacity: 60))
        for width: CGFloat in [500, 900, 1200, 500] {
            host.resize(to: width)
            try assertSectionGeometry(host.grid, sectionCount: 2, tileCount: 10)
        }
    }

    func testSectionsStayPlacedAfterHiddenThenShownAndAppearanceChange() throws {
        let host = Host()
        host.grid.update(sections: Self.groupedSections(), mapping: .index(capacity: 60))
        host.resize(to: 900)
        host.grid.isHidden = true
        host.resize(to: 1200)
        host.grid.isHidden = false
        host.resize(to: 500)
        try assertSectionGeometry(host.grid, sectionCount: 2, tileCount: 10)

        host.window.appearance = NSAppearance(named: .darkAqua)
        host.resize(to: 1200)
        try assertSectionGeometry(host.grid, sectionCount: 2, tileCount: 10)
        host.window.appearance = NSAppearance(named: .aqua)
    }

    func testSectionCountChangesRebuildHeadersAndTilesWithoutLeftovers() throws {
        let host = Host()
        host.resize(to: 900)
        let untitled = [CoreSectionModel(title: nil, slug: nil, color: .systemBlue, cores: Self.tiles(0..<12, kind: nil))]
        for sections in [Self.groupedSections(), untitled, Self.groupedSections(), []] {
            host.grid.update(sections: sections, mapping: .index(capacity: 60))
            host.resize(to: 900)
            let headers = sections.filter { $0.title != nil }.count
            let tiles = sections.reduce(0) { $0 + $1.cores.count }
            XCTAssertEqual(Self.headerLabels(in: host.grid).count, headers)
            XCTAssertEqual(host.grid.subviews.count, headers + tiles, "headers and tiles, nothing left over")
            if headers > 0 {
                try assertSectionGeometry(host.grid, sectionCount: headers, tileCount: tiles)
            }
        }
    }

    func testHeaderTitlesAndTileDescriptionsCarryTheProcessorClass() throws {
        let host = Host()
        host.grid.update(sections: Self.groupedSections(), mapping: .index(capacity: 60))
        host.resize(to: 900)
        let labels = Self.headerLabels(in: host.grid)
        XCTAssertEqual(labels.map { $0.identifier }, ["performance.cpu-cores.section.super", "performance.cpu-cores.section.efficiency"])
        XCTAssertEqual(labels.map { $0.title }, ["Super · 7 cores · 40%", "Efficiency · 3 cores · 20%"])
        let tile = try XCTUnwrap(Self.view(withIdentifier: "performance.cpu-core.8", in: host.grid))
        XCTAssertEqual(tile.accessibilityLabel(), "CPU 8, Efficiency core, 8%")
        host.grid.update(cores: Self.cores(2), mapping: .index(capacity: 60))
        let ungrouped = try XCTUnwrap(Self.view(withIdentifier: "performance.cpu-core.0", in: host.grid))
        XCTAssertEqual(ungrouped.accessibilityLabel(), "CPU 0, 0%")
        XCTAssertTrue(Self.headerLabels(in: host.grid).isEmpty, "an ungrouped list draws no header")
    }

    // MARK: Helpers

    /// Two titled sections, fastest first: a 7-tile class and a 3-tile class, with the second class's tiles
    /// starting at CPU 7.
    private static func groupedSections() -> [CoreSectionModel] {
        [
            CoreSectionModel(title: "Super · 7 cores · 40%", slug: "super", color: .systemPink,
                             cores: tiles(0..<7, kind: "Super")),
            CoreSectionModel(title: "Efficiency · 3 cores · 20%", slug: "efficiency", color: .systemGreen,
                             cores: tiles(7..<10, kind: "Efficiency"))
        ]
    }

    private static func tiles(_ indexes: Range<Int>, kind: String?) -> [CoreTileModel] {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        return indexes.map { index in
            CoreTileModel(index: index, valueText: "\(index)%",
                          series: MetricGraphSeries(name: "CPU \(index)", color: .systemBlue,
                                                    readings: [MetricReading(value: Double(index), unit: .percent,
                                                                             timestamp: timestamp)]),
                          kindName: kind)
        }
    }

    private static func headerLabels(in root: NSView) -> [(identifier: String, title: String)] {
        var labels: [(identifier: String, title: String)] = []
        for view in allViews(in: root) where view.accessibilityIdentifier().hasPrefix("performance.cpu-cores.section.") {
            if let field = view as? NSTextField {
                labels.append((identifier: field.accessibilityIdentifier(), title: field.stringValue))
            }
        }
        return labels
    }

    private static func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
        allViews(in: root).first { $0.accessibilityIdentifier() == identifier }
    }

    private static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }

    /// Grouped layout: each header is a direct subview of the grid and sits above its own tiles, each tile lies in
    /// its section's band, rows and columns follow `columns(for:)`, nothing overlaps, and the grid is exactly as tall
    /// as its lowest view.
    private func assertSectionGeometry(_ grid: CoreGridView, sectionCount: Int, tileCount: Int,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        grid.layoutSubtreeIfNeeded()
        let bounds = grid.bounds
        var headers: [(identifier: String, frame: NSRect)] = []
        var tiles: [(index: Int, frame: NSRect)] = []
        for view in grid.subviews {
            if let label = Self.allViews(in: view).first(where: { $0.accessibilityIdentifier().hasPrefix("performance.cpu-cores.section.") }) {
                headers.append((label.accessibilityIdentifier(), view.frame))
            } else if let graph = Self.allViews(in: view).first(where: { $0.accessibilityIdentifier().hasPrefix("performance.cpu-core.") }),
                      let index = Int(graph.accessibilityIdentifier().dropFirst("performance.cpu-core.".count)) {
                tiles.append((index, view.frame))
            }
        }
        headers.sort { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(headers.count, sectionCount, file: file, line: line)
        XCTAssertEqual(tiles.count, tileCount, file: file, line: line)
        guard headers.count == sectionCount, !headers.isEmpty else { return }

        let columns = grid.columns(for: bounds.width)
        let tileWidth = (bounds.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        for (position, header) in headers.enumerated() {
            XCTAssertEqual(header.frame.width, bounds.width, accuracy: 0.5, file: file, line: line)
            let bandEnd = position + 1 < headers.count ? headers[position + 1].frame.minY : bounds.maxY
            let sectionTiles = tiles.filter { $0.frame.minY >= header.frame.minY && $0.frame.minY < bandEnd }
            XCTAssertFalse(sectionTiles.isEmpty, "\(header.identifier) has tiles", file: file, line: line)
            let firstTop = sectionTiles.map { $0.frame.minY }.min() ?? 0
            XCTAssertLessThanOrEqual(header.frame.maxY, firstTop + 0.5,
                                     "\(header.identifier) must sit above its tiles", file: file, line: line)
            // Tiles are in ascending CPU order within a section, so the position in the section is the index offset.
            let firstIndex = sectionTiles.map { $0.index }.min() ?? 0
            for tile in sectionTiles {
                XCTAssertLessThanOrEqual(tile.frame.maxY, bandEnd + 0.5,
                                         "CPU \(tile.index) must stay inside \(header.identifier)'s band", file: file, line: line)
                let offset = tile.index - firstIndex
                XCTAssertEqual(tile.frame.minX, CGFloat(offset % columns) * (tileWidth + Self.gap),
                               accuracy: 0.5, "CPU \(tile.index) column", file: file, line: line)
                XCTAssertEqual(tile.frame.minY - firstTop, CGFloat(offset / columns) * (Self.tileHeight + Self.gap),
                               accuracy: 0.5, "CPU \(tile.index) row", file: file, line: line)
                XCTAssertEqual(tile.frame.width, tileWidth, accuracy: 0.5, file: file, line: line)
                XCTAssertEqual(tile.frame.height, Self.tileHeight, accuracy: 0.5, file: file, line: line)
            }
        }

        let all = headers.map { $0.frame } + tiles.map { $0.frame }
        for (index, first) in all.enumerated() {
            for second in all.dropFirst(index + 1) {
                let overlap = first.intersection(second)
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                              "views overlap: \(first) and \(second)", file: file, line: line)
            }
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(first),
                          "\(first) must sit inside grid bounds \(bounds)", file: file, line: line)
        }

        let lowest = all.map(\.maxY).max() ?? 0
        XCTAssertEqual(grid.intrinsicContentSize.height, lowest, accuracy: 0.5,
                       "the grid is exactly as tall as its lowest view", file: file, line: line)
        XCTAssertEqual(grid.frame.height, grid.intrinsicContentSize.height, accuracy: 0.5, file: file, line: line)
    }

    private static func cores(_ count: Int) -> [CoreTileModel] {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { index in
            CoreTileModel(index: index, valueText: "\(index)%",
                          series: MetricGraphSeries(name: "CPU \(index)", color: .systemBlue,
                                                    readings: [MetricReading(value: Double(index), unit: .percent,
                                                                             timestamp: timestamp)]))
        }
    }

    private func assertTileGeometry(_ grid: CoreGridView, coreCount: Int,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        grid.layoutSubtreeIfNeeded()
        let tiles = grid.subviews
        XCTAssertEqual(tiles.count, coreCount, file: file, line: line)
        guard coreCount > 0 else {
            XCTAssertEqual(grid.intrinsicContentSize.height, 0, accuracy: 0.5, file: file, line: line)
            return
        }

        let bounds = grid.bounds
        let columns = grid.columns(for: bounds.width)
        let rows = (coreCount + columns - 1) / columns
        let tileWidth = (bounds.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let frames = tiles.map(\.frame)
        for (index, frame) in frames.enumerated() {
            let column = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            XCTAssertEqual(frame.minX, column * (tileWidth + Self.gap), accuracy: 0.5,
                           "tile \(index) column at width \(bounds.width)", file: file, line: line)
            XCTAssertEqual(frame.minY, row * (Self.tileHeight + Self.gap), accuracy: 0.5,
                           "tile \(index) row at width \(bounds.width)", file: file, line: line)
            XCTAssertEqual(frame.width, tileWidth, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(frame.height, Self.tileHeight, accuracy: 0.5, file: file, line: line)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "tile \(index) \(frame) must sit inside grid bounds \(bounds)", file: file, line: line)
        }
        for (index, first) in frames.enumerated() {
            for second in frames.dropFirst(index + 1) {
                let overlap = first.intersection(second)
                XCTAssertTrue(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                              "tiles overlap: \(first) and \(second)", file: file, line: line)
            }
        }

        let expectedHeight = CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.gap
        XCTAssertEqual(grid.intrinsicContentSize.height, expectedHeight, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(grid.frame.height, expectedHeight, accuracy: 0.5,
                       "the grid's frame must follow its row count", file: file, line: line)
    }

    /// A grid pinned to the top and sides of a content view in a real window. Width changes go through the window.
    @MainActor
    private final class Host {
        let window: NSWindow
        let content = NSView()
        let grid = CoreGridView()

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            content.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
            ])
        }

        func resize(to width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 900))
            content.setFrameSize(NSSize(width: width, height: 900))
            content.layoutSubtreeIfNeeded()
        }
    }
}
