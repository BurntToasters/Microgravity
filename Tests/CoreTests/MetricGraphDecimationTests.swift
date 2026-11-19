import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class MetricGraphDecimationTests: XCTestCase {
    /// Deterministic, spread-out values in 0..<1000 so per-column minima and maxima differ.
    private func scrambled(_ index: Int) -> CGFloat {
        CGFloat((index &* 7919) % 1000)
    }

    private func columns(of points: [NSPoint]) -> Set<CGFloat> {
        Set(points.map { $0.x.rounded(.down) })
    }

    func testSegmentsAtOrBelowTwoPointsPerColumnAreUnchanged() {
        XCTAssertEqual(MetricGraphView.decimate([]), [])
        let one = [NSPoint(x: 3, y: 4)]
        XCTAssertEqual(MetricGraphView.decimate(one), one)
        let two = [NSPoint(x: 3, y: 4), NSPoint(x: 3, y: 9)]
        XCTAssertEqual(MetricGraphView.decimate(two), two)

        // Exactly two points per column on average is not above the threshold.
        let exact = (0..<100).map { NSPoint(x: CGFloat($0) * 0.5, y: scrambled($0)) }
        XCTAssertEqual(MetricGraphView.decimate(exact), exact)
    }

    func testFirstAndLastPointsAreKept() {
        let points = (0..<3600).map { NSPoint(x: CGFloat($0) / 10, y: scrambled($0)) }
        let output = MetricGraphView.decimate(points)
        XCTAssertEqual(output.first, points.first)
        XCTAssertEqual(output.last, points.last)
    }

    func testPerColumnMinimumAndMaximumAreKept() {
        let points = (0..<3600).map { NSPoint(x: CGFloat($0) / 10, y: scrambled($0)) }
        let output = MetricGraphView.decimate(points)

        var lowest: [CGFloat: CGFloat] = [:]
        var highest: [CGFloat: CGFloat] = [:]
        for point in points {
            let column = point.x.rounded(.down)
            lowest[column] = min(lowest[column] ?? .infinity, point.y)
            highest[column] = max(highest[column] ?? -.infinity, point.y)
        }
        for column in lowest.keys {
            let kept = output.filter { $0.x.rounded(.down) == column }.map(\.y)
            XCTAssertTrue(kept.contains(lowest[column] ?? .nan), "column \(column) lost its minimum")
            XCTAssertTrue(kept.contains(highest[column] ?? .nan), "column \(column) lost its maximum")
        }
    }

    func testOutputHasAtMostFourPointsPerColumnAndReducesDenseInput() {
        let points = (0..<3600).map { NSPoint(x: CGFloat($0) / 10, y: scrambled($0)) }
        let output = MetricGraphView.decimate(points)
        XCTAssertLessThan(output.count, points.count)
        XCTAssertLessThanOrEqual(output.count, 4 * columns(of: points).count)
    }

    func testOutputKeepsXOrderAndDropsDuplicatePicks() {
        let points = (0..<3600).map { NSPoint(x: CGFloat($0) / 10, y: scrambled($0)) }
        let output = MetricGraphView.decimate(points)
        for (previous, next) in zip(output, output.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.x, next.x)
        }

        // One column with three equal-height points: first and last survive, the middle one is not a pick.
        let flat = [NSPoint(x: 0.1, y: 5), NSPoint(x: 0.2, y: 5), NSPoint(x: 0.3, y: 5)]
        XCTAssertEqual(MetricGraphView.decimate(flat), [flat[0], flat[2]])
    }
}
