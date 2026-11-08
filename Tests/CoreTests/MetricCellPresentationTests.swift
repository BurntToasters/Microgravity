import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class MetricCellPresentationTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private let detail = "3 of 5 members unavailable"

    func testAvailablePercentShowsOnlyTheNumber() {
        let presentation = MetricCellPresentation(MetricReading(value: 42.5, unit: .percent, timestamp: timestamp))

        XCTAssertEqual(presentation.valueText, "42.5%")
        XCTAssertEqual(presentation.badge, .none)
        XCTAssertNil(presentation.badge.symbolName)
        XCTAssertNil(presentation.toolTip)
        XCTAssertEqual(presentation.accessibilityDescription, "42.5%")
        XCTAssertTrue(presentation.isAvailable)
    }

    func testMeasuredZeroIsAValueNotAnUnavailableCell() {
        let presentation = MetricCellPresentation(MetricReading(value: 0, unit: .percent, timestamp: timestamp))

        XCTAssertEqual(presentation.valueText, "0%")
        XCTAssertEqual(presentation.badge, .none)
        XCTAssertTrue(presentation.isAvailable)
    }

    func testPartialPercentKeepsTheNumberAndMovesDetailToTooltipAndAccessibility() {
        let presentation = MetricCellPresentation(MetricReading(
            value: 42.5, unit: .percent, timestamp: timestamp, detail: detail, isPartial: true
        ))

        XCTAssertEqual(presentation.valueText, "42.5%")
        XCTAssertFalse(presentation.valueText.contains("partial"))
        XCTAssertFalse(presentation.valueText.contains(detail))
        XCTAssertEqual(presentation.badge, .partial)
        XCTAssertEqual(presentation.badge.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(presentation.toolTip, "Partial value. \(detail)")
        XCTAssertTrue(presentation.accessibilityDescription.contains("partial"))
        XCTAssertTrue(presentation.accessibilityDescription.contains(detail))
        XCTAssertTrue(presentation.isAvailable)
    }

    func testPartialWithoutDetailGivesAGenericTooltip() {
        let presentation = MetricCellPresentation(MetricReading(
            value: 0, unit: .percent, timestamp: timestamp, isPartial: true
        ))

        XCTAssertEqual(presentation.valueText, "0%")
        XCTAssertEqual(presentation.badge, .partial)
        XCTAssertEqual(presentation.toolTip, "Partial value. Some contributors were not collected.")
    }

    func testUnavailablePercentRendersDashWithReasonInTooltip() {
        let presentation = MetricCellPresentation(MetricReading(
            unavailable: .percent, timestamp: timestamp, reason: .collectionFailed, detail: "capture failed"
        ))

        XCTAssertEqual(presentation.valueText, "—")
        XCTAssertEqual(presentation.badge, .unavailable)
        XCTAssertEqual(presentation.badge.symbolName, "questionmark.circle")
        XCTAssertEqual(presentation.toolTip, "Collection failed · capture failed")
        XCTAssertEqual(presentation.accessibilityDescription, "Unavailable, Collection failed · capture failed")
        XCTAssertFalse(presentation.isAvailable)
    }

    func testUnavailableBytesAndThroughputAreNeverZero() {
        let bytes = MetricCellPresentation(MetricReading(
            unavailable: .bytes, timestamp: timestamp, reason: .permissionDenied
        ))
        let throughput = MetricCellPresentation(MetricReading(
            unavailable: .bytesPerSecond, timestamp: timestamp, reason: .warmingUp
        ))

        XCTAssertEqual(bytes.valueText, "—")
        XCTAssertEqual(throughput.valueText, "—")
        XCTAssertEqual(throughput.toolTip, "Warming up")
        XCTAssertEqual(throughput.badge, .unavailable)
    }

    func testUnavailableWithoutReasonSaysUnavailable() {
        let presentation = MetricCellPresentation(MetricReading(
            unavailable: .percent, timestamp: timestamp, reason: .notCollected
        ))
        XCTAssertEqual(presentation.toolTip, "Not collected")

        let unknown = MetricCellPresentation.unavailable(reason: nil)
        XCTAssertEqual(unknown.toolTip, "Unavailable")
        XCTAssertEqual(unknown.accessibilityDescription, "Unavailable")
    }

    func testAvailableBytesUseMemoryStyle() {
        let value = 2.0 * 1_024 * 1_024 * 1_024
        let presentation = MetricCellPresentation(MetricReading(value: value, unit: .bytes, timestamp: timestamp))

        XCTAssertEqual(presentation.valueText, ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory))
        XCTAssertEqual(presentation.badge, .none)
    }

    func testPartialBytesKeepTheNumberAndBadge() {
        let presentation = MetricCellPresentation(MetricReading(
            value: 512 * 1_024 * 1_024, unit: .bytes, timestamp: timestamp, detail: detail, isPartial: true
        ))

        XCTAssertEqual(presentation.valueText, ByteCountFormatter.string(fromByteCount: 512 * 1_024 * 1_024, countStyle: .memory))
        XCTAssertEqual(presentation.badge, .partial)
        XCTAssertEqual(presentation.toolTip, "Partial value. \(detail)")
    }

    func testThroughputUsesDecimalUnitsAndTheRateSuffix() {
        let presentation = MetricCellPresentation(MetricReading(
            value: 1_000_000, unit: .bytesPerSecond, timestamp: timestamp
        ))
        let decimal = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .decimal)
        let memory = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .memory)

        XCTAssertEqual(presentation.valueText, "\(decimal)/s")
        XCTAssertNotEqual(decimal, memory, "the test is only meaningful when the two styles differ")
        XCTAssertNotEqual(presentation.valueText, "\(memory)/s")
        XCTAssertEqual(presentation.badge, .none)
    }

    func testPartialThroughputKeepsTheNumberAndBadge() {
        let presentation = MetricCellPresentation(MetricReading(
            value: 2_048, unit: .bytesPerSecond, timestamp: timestamp, detail: detail, isPartial: true
        ))

        XCTAssertEqual(presentation.valueText, UIFormat.bytesPerSecond(2_048))
        XCTAssertEqual(presentation.badge, .partial)
        XCTAssertTrue(presentation.accessibilityDescription.contains(detail))
    }

    func testUnavailableCapabilityRendersDashAndReason() {
        let presentation = MetricCellPresentation.unavailable(
            MetricAvailability(available: false, reason: .unsupported, detail: "GPU counters absent")
        )

        XCTAssertEqual(presentation.valueText, "—")
        XCTAssertEqual(presentation.badge, .unavailable)
        XCTAssertEqual(presentation.toolTip, "Unsupported · GPU counters absent")
    }

    func testHeatAlphaIsZeroBelowOnePercentAndRampsToFortyFivePercent() {
        XCTAssertEqual(MetricValueCellView.heatAlpha(intensity: 0, increaseContrast: false), 0)
        XCTAssertEqual(MetricValueCellView.heatAlpha(intensity: 0.009, increaseContrast: false), 0)
        XCTAssertGreaterThan(MetricValueCellView.heatAlpha(intensity: 0.01, increaseContrast: false), 0)
        XCTAssertEqual(MetricValueCellView.heatAlpha(intensity: 1, increaseContrast: false), 0.45, accuracy: 0.0001)
        XCTAssertEqual(MetricValueCellView.heatAlpha(intensity: 0.5, increaseContrast: false),
                       CGFloat(0.45 * pow(0.5, 0.6)), accuracy: 0.0001)
        XCTAssertGreaterThan(MetricValueCellView.heatAlpha(intensity: 0.5, increaseContrast: true),
                             MetricValueCellView.heatAlpha(intensity: 0.5, increaseContrast: false))
        XCTAssertLessThanOrEqual(MetricValueCellView.heatAlpha(intensity: 1, increaseContrast: true), 0.75)
    }

    func testCombinedPairShowsBothValuesAndMarksAPartlyMissingPair() {
        let read = MetricCellPresentation(MetricReading(value: 1_024, unit: .bytesPerSecond, timestamp: timestamp))
        let write = MetricCellPresentation(MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                                         reason: .permissionDenied, detail: detail))
        let pair = MetricCellPresentation.combined([(label: "R", presentation: read), (label: "W", presentation: write)])

        XCTAssertEqual(pair.valueText, "R \(UIFormat.bytesPerSecond(1_024)) · W —")
        XCTAssertEqual(pair.badge, .partial)
        XCTAssertEqual(pair.toolTip, "W: Permission denied · \(detail)")
        XCTAssertEqual(pair.accessibilityDescription,
                       "R \(UIFormat.bytesPerSecond(1_024)), W Unavailable, Permission denied · \(detail)")
    }

    func testCombinedPairIsDashWhenEveryPartIsUnavailable() {
        let missing = MetricCellPresentation.unavailable(reason: .unsupported)
        let pair = MetricCellPresentation.combined([(label: "R", presentation: missing), (label: "W", presentation: missing)])

        XCTAssertEqual(pair.valueText, "—")
        XCTAssertEqual(pair.badge, .unavailable)
    }

    func testCombinedPairWithCompleteValuesHasNoMarkerOrTooltip() {
        let read = MetricCellPresentation(MetricReading(value: 1_024, unit: .bytesPerSecond, timestamp: timestamp))
        let write = MetricCellPresentation(MetricReading(value: 2_048, unit: .bytesPerSecond, timestamp: timestamp))
        let pair = MetricCellPresentation.combined([(label: "R", presentation: read), (label: "W", presentation: write)])

        XCTAssertEqual(pair.valueText, "R \(UIFormat.bytesPerSecond(1_024)) · W \(UIFormat.bytesPerSecond(2_048))")
        XCTAssertEqual(pair.badge, .none)
        XCTAssertNil(pair.toolTip)
    }
}
