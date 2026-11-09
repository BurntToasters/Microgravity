import AppKit
import XCTest
@testable import Microgravity

@MainActor
final class PerformanceViewControllerTests: XCTestCase {
    func testPartialMetricTextKeepsNumericValueUnitDetailAndMeasuredZero() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = "one sampler was unavailable"
        let complete = UIFormat.metric(MetricReading(value: 42.5, unit: .percent, timestamp: timestamp))
        let partial = UIFormat.metric(MetricReading(value: 42.5, unit: .percent, timestamp: timestamp,
                                                    detail: detail, isPartial: true))
        XCTAssertEqual(partial, "\(complete) · partial · \(detail)")

        let zero = UIFormat.metric(MetricReading(value: 0, unit: .percent, timestamp: timestamp))
        let partialZero = UIFormat.metric(MetricReading(value: 0, unit: .percent, timestamp: timestamp,
                                                        isPartial: true))
        XCTAssertNotEqual(zero, "Unavailable")
        XCTAssertEqual(partialZero, "\(zero) · partial")

        let unavailable = MetricReading(unavailable: .percent, timestamp: timestamp,
                                        reason: .collectionFailed, detail: "capture failed", isPartial: true)
        XCTAssertEqual(UIFormat.metric(unavailable), "Collection failed · capture failed")
    }

    func testDiskPresentationNamesCurrentValuesAndTracksHistoryScale() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let read = MetricReading(value: 1_024, unit: .bytesPerSecond, timestamp: timestamp)
        let write = MetricReading(value: 2_048, unit: .bytesPerSecond, timestamp: timestamp)
        let first = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: read,
            firstHistory: [read], secondName: "Write", second: write, secondHistory: [write])
        let largerHistoricalWrite = MetricReading(value: 32_768, unit: .bytesPerSecond, timestamp: timestamp)
        let afterHistoryGrowth = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: read,
            firstHistory: [read], secondName: "Write", second: write,
            secondHistory: [write, largerHistoricalWrite])

        XCTAssertEqual(first.firstValueText, "Read: \(UIFormat.metric(read))")
        XCTAssertEqual(first.secondValueText, "Write: \(UIFormat.metric(write))")
        XCTAssertEqual(first.firstAccessibilityLabel, "Current disk Read throughput")
        XCTAssertEqual(first.secondAccessibilityLabel, "Current disk Write throughput")
        XCTAssertEqual(first.graphMaximum, 5_000)
        XCTAssertEqual(afterHistoryGrowth.graphMaximum, 50_000,
                       "the scale must follow the largest reading retained in graph history")
        XCTAssertEqual(afterHistoryGrowth.scaleText,
                       "Scale maximum: \(UIFormat.bytesPerSecond(50_000))")
        XCTAssertEqual(afterHistoryGrowth.scaleAccessibilityLabel, "Disk throughput graph scale maximum")
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("Disk throughput graph"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("Current Read:"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains("current Write:"))
        XCTAssertTrue(afterHistoryGrowth.accessibilitySummary.contains(afterHistoryGrowth.scaleText))
    }

    func testNetworkPresentationNamesReceiveAndSendValues() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let receive = MetricReading(value: 4_096, unit: .bytesPerSecond, timestamp: timestamp)
        let send = MetricReading(value: 8_192, unit: .bytesPerSecond, timestamp: timestamp)
        let presentation = ThroughputGraphPresentation(
            graphName: "Network throughput", subjectName: "network", firstName: "Receive", first: receive,
            firstHistory: [receive], secondName: "Send", second: send, secondHistory: [send])

        XCTAssertEqual(presentation.firstValueText, "Receive: \(UIFormat.metric(receive))")
        XCTAssertEqual(presentation.secondValueText, "Send: \(UIFormat.metric(send))")
        XCTAssertEqual(presentation.firstAccessibilityLabel, "Current network Receive throughput")
        XCTAssertEqual(presentation.secondAccessibilityLabel, "Current network Send throughput")
        XCTAssertEqual(presentation.graphMaximum, 10_000)
        XCTAssertEqual(presentation.scaleAccessibilityLabel, "Network throughput graph scale maximum")
        XCTAssertTrue(presentation.accessibilitySummary.contains("Network throughput graph"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Current Receive:"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("current Send:"))
    }

    func testScaleMaximumRoundsUpToOneTwoFiveSteps() {
        let expectations: [(value: Double, nice: Double)] = [
            (0.0001, 0.0001), (1, 1), (1.5, 2), (2, 2), (3, 5), (999, 1_000), (1_000, 1_000),
            (1_001, 2_000), (4_096, 5_000), (64_000, 100_000), (512_000, 1_000_000)
        ]
        for (value, nice) in expectations {
            XCTAssertEqual(ThroughputGraphPresentation.niceMaximum(value), nice, accuracy: nice * 1e-12,
                           "scale for \(value)")
        }
        // Samples that wobble around one peak keep one scale label, so it does not jitter.
        let labels = [60_000, 75_000, 99_999].map { UIFormat.bytesPerSecond(ThroughputGraphPresentation.niceMaximum($0)) }
        XCTAssertEqual(Set(labels), [UIFormat.bytesPerSecond(100_000)])
    }

    func testSleepGapTooltipDoesNotClaimThatSamplingWasPaused() {
        XCTAssertEqual(MetricGraphView.sampleGapToolTip, "Sample gap")
    }

    func testUnavailableThroughputHasClearValuesAndNoDataScale() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let permissionDenied = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                             reason: .permissionDenied)
        let unsupported = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                                        reason: .unsupported)
        let presentation = ThroughputGraphPresentation(
            graphName: "Disk throughput", subjectName: "disk", firstName: "Read", first: permissionDenied,
            firstHistory: [permissionDenied], secondName: "Write", second: unsupported,
            secondHistory: [unsupported])

        XCTAssertEqual(presentation.firstValueText, "Read: Permission denied")
        XCTAssertEqual(presentation.secondValueText, "Write: Unsupported")
        XCTAssertEqual(presentation.graphMaximum, 1, "an empty graph retains its drawing fallback")
        XCTAssertEqual(presentation.scaleText, "Scale maximum: no data")
        XCTAssertTrue(presentation.accessibilitySummary.contains("No graph samples have available data"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Current Read: Permission denied"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("current Write: Unsupported"))
        XCTAssertTrue(presentation.accessibilitySummary.contains("Scale maximum: no data"))
    }

    func testControllerWiresThroughputValuesScaleAndAccessibilityAtNarrowWidth() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let earlierTimestamp = timestamp.addingTimeInterval(-2)
        let laterHistoryTimestamp = timestamp.addingTimeInterval(-1)
        let current = throughputSnapshot(
            timestamp: timestamp,
            diskRead: reading(1_024, timestamp), diskWrite: reading(2_048, timestamp),
            networkReceive: reading(4_096, timestamp), networkSend: reading(8_192, timestamp))
        let earlier = throughputSnapshot(
            timestamp: earlierTimestamp,
            diskRead: reading(16_384, earlierTimestamp), diskWrite: reading(32_768, earlierTimestamp),
            networkReceive: reading(32_768, earlierTimestamp), networkSend: reading(65_536, earlierTimestamp))
        let latestHistory = throughputSnapshot(
            timestamp: laterHistoryTimestamp,
            diskRead: reading(64_000, laterHistoryTimestamp), diskWrite: reading(48_000, laterHistoryTimestamp),
            networkReceive: reading(128_000, laterHistoryTimestamp), networkSend: reading(96_000, laterHistoryTimestamp))
        let store = MutablePerformanceMonitoringStore()
        let controller = makeController(store: store)
        controller.view.setFrameSize(NSSize(width: 640, height: 600))

        store.replace(snapshot: current, samples: [earlier, latestHistory, current].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: current)
        controller.selectMetric(.disk)
        controller.view.layoutSubtreeIfNeeded()

        let diskRead = try XCTUnwrap(view(withIdentifier: "performance.disk.read.value", in: controller.view) as? NSTextField)
        let diskWrite = try XCTUnwrap(view(withIdentifier: "performance.disk.write.value", in: controller.view) as? NSTextField)
        let diskScale = try XCTUnwrap(view(withIdentifier: "performance.graph.disk.scale", in: controller.view) as? NSTextField)
        let diskGraph = try XCTUnwrap(view(withIdentifier: "performance.graph.disk", in: controller.view))

        XCTAssertEqual(diskRead.stringValue, UIFormat.metric(current.system.diskReadBytesPerSecond))
        XCTAssertEqual(diskWrite.stringValue, UIFormat.metric(current.system.diskWriteBytesPerSecond))
        XCTAssertEqual(diskRead.accessibilityLabel(), "Current disk Read throughput")
        XCTAssertEqual(diskWrite.accessibilityLabel(), "Current disk Write throughput")
        XCTAssertEqual(diskScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(100_000))")
        XCTAssertEqual(diskScale.accessibilityLabel(), "Disk throughput graph scale maximum")
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Disk throughput graph") == true)
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Current Read:") == true)
        XCTAssertTrue(diskGraph.accessibilityLabel()?.contains("Scale maximum: \(UIFormat.bytesPerSecond(100_000))") == true)

        controller.selectMetric(.network)
        controller.view.layoutSubtreeIfNeeded()
        let networkReceive = try XCTUnwrap(view(withIdentifier: "performance.network.receive.value", in: controller.view) as? NSTextField)
        let networkSend = try XCTUnwrap(view(withIdentifier: "performance.network.send.value", in: controller.view) as? NSTextField)
        let networkScale = try XCTUnwrap(view(withIdentifier: "performance.graph.network.scale", in: controller.view) as? NSTextField)
        let networkGraph = try XCTUnwrap(view(withIdentifier: "performance.graph.network", in: controller.view))

        XCTAssertEqual(networkReceive.stringValue, UIFormat.metric(current.system.networkReceiveBytesPerSecond))
        XCTAssertEqual(networkSend.stringValue, UIFormat.metric(current.system.networkTransmitBytesPerSecond))
        XCTAssertEqual(networkReceive.accessibilityLabel(), "Current network Receive throughput")
        XCTAssertEqual(networkSend.accessibilityLabel(), "Current network Send throughput")
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(200_000))")
        XCTAssertEqual(networkScale.accessibilityLabel(), "Network throughput graph scale maximum")
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("Current Receive:") == true)
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("Scale maximum: \(UIFormat.bytesPerSecond(200_000))") == true)

        let expandedTimestamp = timestamp.addingTimeInterval(1)
        let expandedCurrent = throughputSnapshot(
            timestamp: expandedTimestamp,
            diskRead: reading(256_000, expandedTimestamp), diskWrite: reading(192_000, expandedTimestamp),
            networkReceive: reading(512_000, expandedTimestamp), networkSend: reading(384_000, expandedTimestamp))
        store.replace(snapshot: expandedCurrent,
                      samples: [earlier, latestHistory, current, expandedCurrent].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: expandedCurrent)
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(1_000_000))",
                       "the controller must refresh the scale as graph history changes")

        let detail = String(repeating: "Permission detail that should truncate safely. ", count: 12)
        let unavailableTimestamp = expandedTimestamp.addingTimeInterval(1)
        let unavailable = throughputSnapshot(
            timestamp: unavailableTimestamp,
            diskRead: unavailableReading(unavailableTimestamp, detail), diskWrite: unavailableReading(unavailableTimestamp, detail),
            networkReceive: unavailableReading(unavailableTimestamp, detail), networkSend: unavailableReading(unavailableTimestamp, detail))
        store.replace(snapshot: unavailable,
                      samples: [earlier, latestHistory, current, expandedCurrent].map { MonitoringGraphSample(snapshot: $0) })
        controller.update(snapshot: unavailable)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(networkReceive.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertTrue(networkSend.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertEqual(networkScale.stringValue, "Scale maximum: \(UIFormat.bytesPerSecond(1_000_000))",
                       "unavailable current data must not erase the historical graph scale")
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("Current Receive: Permission denied · \(detail)") == true)
        XCTAssertTrue(networkGraph.accessibilityLabel()?.contains("current Send: Permission denied · \(detail)") == true)

        for field in [networkReceive, networkSend] {
            XCTAssertEqual(field.lineBreakMode, .byTruncatingTail)
            XCTAssertTrue(field.usesSingleLineMode)
            let inPage = field.convert(field.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(inPage.minX, 0)
            XCTAssertLessThanOrEqual(inPage.maxX, controller.view.bounds.maxX - 16,
                                     "long unavailable details must stay within the page width")
        }

        controller.selectMetric(.disk)
        controller.view.layoutSubtreeIfNeeded()
        let truncatedRead = try XCTUnwrap(view(withIdentifier: "performance.disk.read.value", in: controller.view) as? NSTextField)
        XCTAssertTrue(truncatedRead.stringValue.contains("Permission denied · \(detail)"))
        XCTAssertEqual(truncatedRead.lineBreakMode, .byTruncatingTail)
        XCTAssertTrue(truncatedRead.usesSingleLineMode)
        let inPage = truncatedRead.convert(truncatedRead.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(inPage.maxX, controller.view.bounds.maxX - 16)
    }

    func testRailMarksCapabilityOffMetricsUnavailableWithoutAnySparkline() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let gpuReading = MetricReading(unavailable: .percent, timestamp: timestamp, reason: .unsupported,
                                       detail: "GPU provider absent")
        let energyReading = MetricReading(unavailable: .joules, timestamp: timestamp, reason: .unsupported)
        let snapshot = MonitoringSnapshot(
            timestamp: timestamp, system: base.system, processes: [], processGroups: [], startupItems: [],
            services: [], users: [], discoveryCoverage: [:],
            capabilities: [
                .gpu: MetricAvailability(available: false, reason: .unsupported, detail: "GPU provider absent"),
                .energy: MetricAvailability(available: false, reason: .unsupported)
            ],
            advancedMetrics: [.gpu: gpuReading, .energy: energyReading])
        let samples = [MonitoringGraphSample(snapshot: snapshot)]

        let items = PerformancePresenter.railItems(snapshot: snapshot, samples: samples)
        let gpu = items.first { $0.metric == .gpu }
        let energy = items.first { $0.metric == .energy }
        XCTAssertEqual(gpu?.valueText, "Unavailable")
        XCTAssertEqual(gpu?.isValueUnavailable, true)
        XCTAssertEqual(gpu?.sparkline.isEmpty, true, "an unavailable metric must not draw a zero series")
        XCTAssertEqual(energy?.valueText, "Unavailable")
        XCTAssertEqual(energy?.sparkline.isEmpty, true)

        let gpuDetail = PerformancePresenter.detail(metric: .gpu, snapshot: snapshot, samples: samples,
                                                    window: .oneMinute, cpuMode: .overall)
        XCTAssertEqual(gpuDetail.stateText, "Unsupported")
        XCTAssertNotNil(gpuDetail.banner)
        XCTAssertTrue(gpuDetail.series.first?.readings.allSatisfy { $0.value == nil } == true,
                      "unavailable readings are plotted as no data, never as zero")
    }

    /// Energy is reported in watts by default; with no reading yet, its detail must not claim joules.
    func testEnergyDetailWithoutReadingsDefaultsToWatts() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let snapshot = MonitoringSnapshot(
            timestamp: timestamp, system: base.system, processes: [], processGroups: [], startupItems: [],
            services: [], users: [], discoveryCoverage: [:], capabilities: [:], advancedMetrics: [:])
        let samples = [MonitoringGraphSample(snapshot: snapshot)]

        let detail = PerformancePresenter.detail(metric: .energy, snapshot: snapshot, samples: samples,
                                                 window: .oneMinute, cpuMode: .overall)
        XCTAssertTrue(detail.subtitle.hasPrefix("Power in watts"), detail.subtitle)
        XCTAssertEqual(detail.stats.first { $0.label == "Unit" }?.value, "Watts")
    }

    func testWindowKeepsSamplesInsideTheWindowAndNamesTheRealSpan() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0...120).map { offset in
            MonitoringGraphSample(snapshot: CoreTestFixtures.snapshot(timestamp: end.addingTimeInterval(Double(offset - 120))))
        }

        let oneMinute = PerformancePresenter.windowed(samples, .oneMinute)
        XCTAssertEqual(oneMinute.count, 61, "a 60 s window keeps the newest 60 seconds of one-second samples")
        XCTAssertEqual(PerformancePresenter.windowed(samples, .oneHour).count, 121, "a window longer than the data keeps every sample")
        let span = PerformancePresenter.spanText(PerformancePresenter.spanDuration(oneMinute))
        XCTAssertEqual(span.short, "60 s")
        XCTAssertEqual(span.long, "60 seconds")
        XCTAssertEqual(PerformancePresenter.spanText(300).short, "5 min")
        XCTAssertEqual(PerformancePresenter.spanText(720).long, "12 minutes")
        XCTAssertEqual(PerformancePresenter.spanText(1).long, "1 second")
    }

    func testDetailSpanLabelDescribesThePlottedWindowNotTheDataPresent() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        // 30 one-second samples: only 29 s of data exist, but the 60 s window is what the plot spans.
        let samples = (0..<30).map { offset in
            MonitoringGraphSample(snapshot: CoreTestFixtures.snapshot(timestamp: end.addingTimeInterval(Double(offset))))
        }
        let snapshot = CoreTestFixtures.snapshot(timestamp: end.addingTimeInterval(29))

        let windowed = PerformancePresenter.detail(metric: .cpu, snapshot: snapshot, samples: samples,
                                                   window: .oneMinute, cpuMode: .overall)
        XCTAssertEqual(windowed.spanLabel, "60 s")
        XCTAssertEqual(windowed.timeSpan, 60)
        XCTAssertTrue(windowed.subtitle.hasSuffix("over 29 seconds"), windowed.subtitle)

        let fiveMinutes = PerformancePresenter.detail(metric: .cpu, snapshot: snapshot, samples: samples,
                                                      window: .fiveMinutes, cpuMode: .overall)
        XCTAssertEqual(fiveMinutes.spanLabel, "5 min")

        let oneHour = PerformancePresenter.detail(metric: .cpu, snapshot: snapshot, samples: samples,
                                                  window: .oneHour, cpuMode: .overall)
        XCTAssertEqual(oneHour.spanLabel, "1 h", "the plot spans the whole hour even while only 29 s exist")
        XCTAssertEqual(oneHour.timeSpan, 3600)
    }

    func testPerformanceWindowsOfferOneMinuteToOneHour() {
        XCTAssertEqual(PerformanceWindow.allCases.map(\.title), ["1 min", "5 min", "15 min", "1 h"])
        XCTAssertEqual(PerformanceWindow.allCases.map(\.duration), [60, 300, 900, 3600])
    }

    func testFifteenMinuteWindowKeepsOnlyItsOwnSamples() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0...3600).map { offset in
            MonitoringGraphSample(snapshot: CoreTestFixtures.snapshot(timestamp: end.addingTimeInterval(Double(offset - 3600))))
        }

        XCTAssertEqual(PerformancePresenter.windowed(samples, .fifteenMinutes).count, 901)
        XCTAssertEqual(PerformancePresenter.windowed(samples, .oneHour).count, 3601)
        XCTAssertEqual(PerformancePresenter.spanText(PerformanceWindow.fifteenMinutes.duration).short, "15 min")
    }

    func testMemoryDetailShowsBreakdownAndNeverZeroForMissingFields() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let system = base.system
        let collected = SystemMetricsSnapshot(
            capacityCores: system.capacityCores, cpuPercent: system.cpuPercent,
            perCoreCPUPercent: system.perCoreCPUPercent,
            memoryUsedBytes: system.memoryUsedBytes, memoryAvailableBytes: system.memoryAvailableBytes,
            memoryTotalBytes: system.memoryTotalBytes,
            memoryAppBytes: CoreTestFixtures.reading(2_100_000_000, unit: .bytes, timestamp: timestamp),
            memoryWiredBytes: CoreTestFixtures.reading(1_200_000_000, unit: .bytes, timestamp: timestamp),
            memoryCompressedBytes: CoreTestFixtures.reading(500_000_000, unit: .bytes, timestamp: timestamp),
            memoryCachedFilesBytes: MetricReading(unavailable: .bytes, timestamp: timestamp, reason: .permissionDenied),
            memoryPressure: system.memoryPressure, swapUsedBytes: system.swapUsedBytes,
            swapTotalBytes: system.swapTotalBytes, diskReadBytesPerSecond: system.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: system.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: system.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: system.networkTransmitBytesPerSecond,
            networkInterfaces: system.networkInterfaces)
        let snapshot = MonitoringSnapshot(timestamp: timestamp, system: collected, processes: [], processGroups: [],
                                          startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                          capabilities: [:])
        let samples = [MonitoringGraphSample(snapshot: snapshot)]

        let detail = PerformancePresenter.detail(metric: .memory, snapshot: snapshot, samples: samples,
                                                 window: .oneMinute, cpuMode: .overall)
        XCTAssertEqual(detail.stats.map(\.label), ["Used", "Available", "Total", "App memory", "Wired",
                                                   "Compressed", "Cached files"])
        XCTAssertEqual(detail.stats.first { $0.label == "App memory" }?.value, UIFormat.value(collected.memoryAppBytes!))
        XCTAssertEqual(detail.stats.first { $0.label == "Wired" }?.value, UIFormat.value(collected.memoryWiredBytes!))
        XCTAssertEqual(detail.stats.first { $0.label == "Compressed" }?.value, UIFormat.value(collected.memoryCompressedBytes!))
        XCTAssertEqual(detail.stats.first { $0.label == "Cached files" }?.value, UIFormat.unavailable(.permissionDenied))

        // A snapshot from before the breakdown existed: nil fields read as not collected, never as zero.
        let legacyDetail = PerformancePresenter.detail(metric: .memory, snapshot: base, samples: samples,
                                                       window: .oneMinute, cpuMode: .overall)
        XCTAssertEqual(legacyDetail.stats.count, 7)
        for label in ["App memory", "Wired", "Compressed", "Cached files"] {
            XCTAssertEqual(legacyDetail.stats.first { $0.label == label }?.value, "Not collected", label)
        }
    }

    func testAdvancedBannerDoesNotDoublePunctuation() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let snapshot = MonitoringSnapshot(
            timestamp: timestamp, system: base.system, processes: [], processGroups: [], startupItems: [],
            services: [], users: [], discoveryCoverage: [:],
            capabilities: [.gpu: MetricAvailability(available: false, reason: .unsupported, detail: "Provider absent.")],
            advancedMetrics: [:])
        let samples = [MonitoringGraphSample(snapshot: snapshot)]

        let detail = PerformancePresenter.detail(metric: .gpu, snapshot: snapshot, samples: samples,
                                                 window: .oneMinute, cpuMode: .overall)
        XCTAssertEqual(detail.banner?.message, "Unsupported · Provider absent. Shown as no data, never as zero.")
        XCTAssertFalse(detail.banner?.message.contains("..") == true)
    }

    func testCoreGridUsesFourToSixColumnsByWidth() throws {
        let grid = CoreGridView()
        let cores = (0..<12).map { index in
            CoreTileModel(index: index, valueText: "10%",
                          series: MetricGraphSeries(name: "CPU \(index)", color: .systemBlue,
                                                    readings: [MetricReading(value: 10, unit: .percent, timestamp: Date())]))
        }
        grid.update(cores: cores, mapping: .index(capacity: 60))
        grid.setFrameSize(NSSize(width: 460, height: 400))
        grid.layoutSubtreeIfNeeded()

        XCTAssertEqual(grid.columns(for: 200), 4, "never fewer than four per row")
        XCTAssertEqual(grid.columns(for: 460), 4)
        XCTAssertEqual(grid.columns(for: 900), 6, "never more than six per row")

        let first = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.0", in: grid))
        let fifth = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.4", in: grid))
        let firstFrame = first.convert(first.bounds, to: grid)
        let fifthFrame = fifth.convert(fifth.bounds, to: grid)
        XCTAssertEqual(firstFrame.minX, fifthFrame.minX, accuracy: 0.5, "the fifth core wraps to the first column")
        XCTAssertGreaterThan(fifthFrame.minY, firstFrame.minY, "the fifth core starts a second row")
    }

    func testCPULogicalProcessorModeShowsPerCoreGraphsInsteadOfOverallGraph() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let cores = (0..<6).map { CoreTestFixtures.reading(Double($0 * 10), unit: .percent, timestamp: timestamp) }
        let original = base.system
        let system = SystemMetricsSnapshot(
            capacityCores: 6, cpuPercent: original.cpuPercent, perCoreCPUPercent: cores,
            memoryUsedBytes: original.memoryUsedBytes, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: original.memoryTotalBytes, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: original.diskReadBytesPerSecond, diskWriteBytesPerSecond: original.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: original.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: original.networkTransmitBytesPerSecond,
            networkInterfaces: [])
        let snapshot = MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: [],
                                          startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                          capabilities: [:])
        let store = MutablePerformanceMonitoringStore()
        store.replace(snapshot: snapshot, samples: [MonitoringGraphSample(snapshot: snapshot)])
        let controller = makeController(store: store)
        controller.view.setFrameSize(NSSize(width: 960, height: 600))
        controller.update(snapshot: snapshot)

        let overall = try XCTUnwrap(view(withIdentifier: "performance.graph.cpu-total", in: controller.view))
        XCTAssertFalse(overall.isHidden)

        controller.setCPUMode(.logicalProcessors)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(overall.isHidden)
        XCTAssertNotNil(view(withIdentifier: "performance.graph.cpu-cores", in: controller.view))
        for index in 0..<6 {
            let tile = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.\(index)", in: controller.view))
            XCTAssertNotNil(tile)
        }
        XCTAssertEqual(controller.cpuMode, .logicalProcessors)
    }

    func testLogicalProcessorGridSitsBelowModeControlAndKeepsTilesInsideAtTwoWindowSizes() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let cores = (0..<18).map { CoreTestFixtures.reading(Double($0 * 5), unit: .percent, timestamp: timestamp) }
        let original = base.system
        let system = SystemMetricsSnapshot(
            capacityCores: 18, cpuPercent: original.cpuPercent, perCoreCPUPercent: cores,
            memoryUsedBytes: original.memoryUsedBytes, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: original.memoryTotalBytes, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: original.diskReadBytesPerSecond, diskWriteBytesPerSecond: original.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: original.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: original.networkTransmitBytesPerSecond,
            networkInterfaces: [])
        let snapshot = MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: [],
                                          startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                          capabilities: [:])

        for size in [NSSize(width: 960, height: 600), NSSize(width: 1280, height: 820)] {
            let store = MutablePerformanceMonitoringStore()
            store.replace(snapshot: snapshot, samples: [MonitoringGraphSample(snapshot: snapshot)])
            let controller = makeController(store: store)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.view
            controller.view.setFrameSize(size)
            controller.update(snapshot: snapshot)
            controller.setCPUMode(.logicalProcessors)
            controller.view.layoutSubtreeIfNeeded()

            let control = try XCTUnwrap(view(withIdentifier: "performance.cpu.mode", in: controller.view))
            let grid = try XCTUnwrap(view(withIdentifier: "performance.graph.cpu-cores", in: controller.view))
            XCTAssertFalse(grid.isHidden, "\(size)")
            let gridRect = grid.convert(grid.bounds, to: nil)
            let controlRect = control.convert(control.bounds, to: nil)
            XCTAssertLessThanOrEqual(gridRect.maxY, controlRect.minY + 0.5,
                                     "the processor grid must sit below the CPU mode control at \(size)")
            XCTAssertGreaterThan(gridRect.height, 0, "\(size)")
            XCTAssertEqual(grid.frame.height, grid.intrinsicContentSize.height, accuracy: 0.5,
                           "the grid's height must match its tile rows at \(size)")
            let caption = try XCTUnwrap(view(withIdentifier: "performance.detail.caption", in: controller.view))
            XCTAssertLessThanOrEqual(caption.convert(caption.bounds, to: nil).maxY, gridRect.minY + 0.5,
                                     "the caption must sit below the processor grid at \(size)")

            for index in 0..<18 {
                let graph = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.\(index)", in: controller.view))
                let tile = try XCTUnwrap(graph.superview)
                XCTAssertTrue(grid.bounds.insetBy(dx: -0.5, dy: -0.5).contains(tile.frame),
                              "tile \(index) \(tile.frame) must sit inside the grid \(grid.bounds) at \(size)")
            }
        }
    }

    // MARK: Processor sections

    func testProcessorSectionsFollowTopologyFastestFirstWithAveragesAndCPUIndexes() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        // Efficiency is listed first in the topology; the presenter still puts the faster Performance class first.
        let snapshot = sectionSnapshot(
            perCore: [50, nil, 70, 90, 10, 20, 30, 40],
            kinds: [ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [0, 1, 2, 3]),
                    ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: [4, 5, 6, 7])])
        let model = sectionDetail(snapshot)

        XCTAssertEqual(model.coreSections.map(\.slug), ["performance", "efficiency"])
        XCTAssertEqual(model.coreSections[0].title, "Performance · 4 cores · \(UIFormat.percent(25))")
        // The missing CPU 1 reading is left out of the average, not counted as zero: (50 + 70 + 90) / 3.
        XCTAssertEqual(model.coreSections[1].title, "Efficiency · 4 cores · \(UIFormat.percent(70))")
        XCTAssertEqual(model.coreSections[0].cores.map(\.index), [4, 5, 6, 7])
        XCTAssertEqual(model.coreSections[1].cores.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(model.cores.map(\.index), [4, 5, 6, 7, 0, 1, 2, 3])
        XCTAssertEqual(model.coreSections[0].cores.first?.kindName, "Performance")
        XCTAssertEqual(model.coreSections[1].cores.first?.kindName, "Efficiency")
        XCTAssertEqual(model.coreSections[1].cores[1].valueText, UIFormat.unavailable(.warmingUp))
    }

    func testProcessorSectionColorsFollowCustomizedRolesInHeadersAndTiles() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let snapshot = sectionSnapshot(perCore: [10, 20, 30, 40, 50, 60, 70, 80],
                                       kinds: [ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: [4, 5, 6, 7]),
                                               ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [0, 1, 2, 3])])
        let defaultModel = sectionDetail(snapshot)
        assertSameSRGB(defaultModel.coreSections[0].color, ColorPreferences.color(for: .performanceCores))
        assertSameSRGB(defaultModel.coreSections[1].cores[0].series.color, ColorPreferences.color(for: .efficiencyCores))

        let custom = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        ColorPreferences.setColor(custom, for: .performanceCores)
        let model = sectionDetail(snapshot)
        assertSameSRGB(model.coreSections[0].color, custom)
        for tile in model.coreSections[0].cores {
            assertSameSRGB(tile.series.color, custom)
        }
        // The efficiency class keeps its own role color.
        assertSameSRGB(model.coreSections[1].color, ColorPreferences.color(for: .efficiencyCores))
    }

    func testUnknownProcessorClassNamesGetRolesByPosition() {
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Mid", position: 0, count: 2), .performanceCores)
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Mid", position: 1, count: 2), .efficiencyCores)
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Mid", position: 0, count: 3), .superCores)
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Mid", position: 1, count: 3), .performanceCores)
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Mid", position: 2, count: 3), .efficiencyCores)
        XCTAssertEqual(PerformancePresenter.colorRole(forKindNamed: "Super", position: 1, count: 2), .superCores)
    }

    func testUnknownProcessorClassKeepsItsNameInTheTitleAndSlug() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let snapshot = sectionSnapshot(perCore: [10, 20], kinds: [ProcessorCoreKind(name: "Mid Tier", rank: 0, logicalCPUs: [0, 1])])
        let model = sectionDetail(snapshot)
        XCTAssertEqual(model.coreSections.map(\.slug), ["mid-tier"])
        XCTAssertEqual(model.coreSections.first?.title, "Mid Tier · 2 cores · \(UIFormat.percent(15))")
    }

    func testAllUnavailableProcessorClassReadsUnavailableNeverZero() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let snapshot = sectionSnapshot(
            perCore: [nil, nil, 40, 60],
            kinds: [ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: [2, 3]),
                    ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [0, 1])])
        let model = sectionDetail(snapshot)
        XCTAssertEqual(model.coreSections[1].title, "Efficiency · 2 cores · Unavailable")
        XCTAssertEqual(model.coreSections[1].cores.map(\.valueText), [UIFormat.unavailable(.warmingUp), UIFormat.unavailable(.warmingUp)])
        XCTAssertEqual(PerformancePresenter.averageText([nil, nil]), "Unavailable")
        XCTAssertFalse(model.coreSections[1].title?.contains("0%") ?? false, "a missing class must not read as 0%")
    }

    func testUngroupedCoresWithoutTopologyAreOneUntitledSectionInTheCPUColor() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let snapshot = sectionSnapshot(perCore: [10, 20, 30, 40], kinds: nil)
        let model = sectionDetail(snapshot)

        XCTAssertEqual(model.coreSections.count, 1)
        XCTAssertNil(model.coreSections[0].title)
        XCTAssertNil(model.coreSections[0].slug)
        XCTAssertEqual(model.coreSections[0].cores.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(model.coreSections[0].cores.allSatisfy { $0.kindName == nil })
        assertSameSRGB(model.coreSections[0].color, PerformanceMetric.cpu.color)
        assertSameSRGB(model.coreSections[0].cores[2].series.color, PerformanceMetric.cpu.color)
    }

    func testTopologyThatDoesNotListEveryProcessorExactlyOnceFallsBackToOneList() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let snapshot = sectionSnapshot(
            perCore: [10, 20, 30, 40],
            kinds: [ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: [0, 1]),
                    ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [1, 2])])
        let model = sectionDetail(snapshot)
        XCTAssertEqual(model.coreSections.count, 1)
        XCTAssertNil(model.coreSections[0].title)
        XCTAssertEqual(model.cores.count, 4)
    }

    func testCPUStatsNameOneCountPerProcessorClassWithTopology() {
        let colors = SectionColorDefaults()
        defer { colors.restore() }
        let grouped = sectionDetail(sectionSnapshot(
            perCore: Array(repeating: 10, count: 8),
            kinds: [ProcessorCoreKind(name: "Performance", rank: 0, logicalCPUs: [4, 5, 6, 7]),
                    ProcessorCoreKind(name: "Efficiency", rank: 1, logicalCPUs: [0, 1, 2, 3])]))
        XCTAssertEqual(grouped.stats.map(\.label), ["Performance cores", "Efficiency cores", "Processes", "Uptime"])
        XCTAssertEqual(grouped.stats.prefix(2).map(\.value), ["4", "4"])

        let ungrouped = sectionDetail(sectionSnapshot(perCore: Array(repeating: 10, count: 8), kinds: nil))
        XCTAssertEqual(ungrouped.stats.map(\.label), ["Logical processors", "Processes", "Uptime"])
        XCTAssertEqual(ungrouped.stats.first?.value, "8")
    }

    /// The fixture topology (Performance 4 to 7, Efficiency 0 to 3) in the real Logical Processors mode at 1280 by 820.
    func testFixtureLogicalProcessorModeShowsBothProcessorSectionHeadersAboveTheirTiles() throws {
        let fixture = FixtureMonitoringStore(configuration: FixtureConfiguration(arguments: []))
        let snapshot = try XCTUnwrap(fixture.latestSnapshot)
        let dependencies = PageDependencies(monitoringStore: fixture, processActions: UnusedProcessActioner(),
                                            integrations: UnavailableSystemIntegrationAPI(), fixtureMode: true)
        let controller = PerformanceViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.setFrameSize(size)
        controller.update(snapshot: snapshot)
        controller.setCPUMode(.logicalProcessors)
        controller.view.layoutSubtreeIfNeeded()

        let perfHeader = try XCTUnwrap(view(withIdentifier: "performance.cpu-cores.section.performance", in: controller.view) as? NSTextField)
        let effHeader = try XCTUnwrap(view(withIdentifier: "performance.cpu-cores.section.efficiency", in: controller.view) as? NSTextField)
        let perfValues = [4, 5, 6, 7].compactMap { snapshot.system.perCoreCPUPercent[$0].value }
        let effValues = [0, 1, 2, 3].compactMap { snapshot.system.perCoreCPUPercent[$0].value }
        XCTAssertEqual(perfHeader.stringValue, "Performance · 4 cores · \(UIFormat.percent(perfValues.reduce(0, +) / 4))")
        XCTAssertEqual(effHeader.stringValue, "Efficiency · 4 cores · \(UIFormat.percent(effValues.reduce(0, +) / 4))")
        XCTAssertFalse(perfHeader.isHidden)
        XCTAssertFalse(effHeader.isHidden)

        let perfRect = perfHeader.convert(perfHeader.bounds, to: nil)
        let effRect = effHeader.convert(effHeader.bounds, to: nil)
        // Window coordinates: higher y is higher on screen. Performance comes first, so its header is above Efficiency's.
        XCTAssertGreaterThan(perfRect.minY, effRect.maxY, "the Performance header must sit above the Efficiency header")
        for index in 4...7 {
            let tile = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.\(index)", in: controller.view)?.superview)
            XCTAssertGreaterThanOrEqual(perfRect.minY, tile.convert(tile.bounds, to: nil).maxY - 0.5,
                                        "the Performance header must sit above CPU \(index)")
        }
        for index in 0...3 {
            let tile = try XCTUnwrap(view(withIdentifier: "performance.cpu-core.\(index)", in: controller.view)?.superview)
            XCTAssertGreaterThanOrEqual(effRect.minY, tile.convert(tile.bounds, to: nil).maxY - 0.5,
                                        "the Efficiency header must sit above CPU \(index)")
        }
    }

    func testPauseToolbarItemKeepsIdentifierAndTogglesSampling() throws {
        let store = MutablePerformanceMonitoringStore()
        let controller = makeController(store: store)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.toolbarItemIdentifiers.count, 2)
        let item = try XCTUnwrap(controller.toolbarItem(for: PerformanceViewController.pauseItemIdentifier))
        let button = try XCTUnwrap(item.view as? NSButton)
        XCTAssertEqual(button.accessibilityIdentifier(), "performance.action.pause")
        XCTAssertEqual(button.title, "Pause")

        button.performClick(nil)
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(button.title, "Resume")
        button.performClick(nil)
        XCTAssertFalse(store.isPaused)
        XCTAssertEqual(button.title, "Pause")
    }

    func testRefreshIntervalPopUpWritesTheSettingsInterval() throws {
        let defaults = UserDefaults.standard
        let priorInterval = defaults.object(forKey: "monitoring.refreshInterval")
        defer {
            if let priorInterval { defaults.set(priorInterval, forKey: "monitoring.refreshInterval") }
            else { defaults.removeObject(forKey: "monitoring.refreshInterval") }
        }

        let store = MutablePerformanceMonitoringStore()
        let controller = makeController(store: store)
        controller.loadViewIfNeeded()
        let item = try XCTUnwrap(controller.toolbarItem(for: PerformanceViewController.refreshItemIdentifier))
        let popUp = try XCTUnwrap(item.view as? NSPopUpButton)
        XCTAssertEqual(popUp.numberOfItems, MonitoringInterval.allCases.count)

        popUp.selectItem(at: 3)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        XCTAssertEqual(store.interval, .fiveSeconds)
        XCTAssertEqual(defaults.double(forKey: "monitoring.refreshInterval"), 5)
    }

    func testSettingsIntervalAndPauseReachThePerformanceToolbar() throws {
        let defaults = UserDefaults.standard
        let priorInterval = defaults.object(forKey: SamplingControls.refreshIntervalDefaultsKey)
        defer {
            if let priorInterval { defaults.set(priorInterval, forKey: SamplingControls.refreshIntervalDefaultsKey) }
            else { defaults.removeObject(forKey: SamplingControls.refreshIntervalDefaultsKey) }
        }

        let store = MutablePerformanceMonitoringStore()
        let performance = makeController(store: store)
        let settings = SettingsViewController(dependencies: PageDependencies(
            monitoringStore: store,
            processActions: UnusedProcessActioner(),
            integrations: UnavailableSystemIntegrationAPI(),
            fixtureMode: false
        ))
        settings.loadViewIfNeeded()

        let toolbarPopUp = try XCTUnwrap(performance.toolbarItem(for: PerformanceViewController.refreshItemIdentifier)?.view as? NSPopUpButton)
        let toolbarPause = try XCTUnwrap(performance.toolbarItem(for: PerformanceViewController.pauseItemIdentifier)?.view as? NSButton)
        let settingsPopUp = try XCTUnwrap(view(withIdentifier: "settings.refresh", in: settings.view) as? NSPopUpButton)
        let settingsPause = try XCTUnwrap(view(withIdentifier: "settings.sampling.pause", in: settings.view) as? NSButton)

        settingsPopUp.selectItem(at: 3)
        _ = settingsPopUp.sendAction(settingsPopUp.action, to: settingsPopUp.target)
        XCTAssertEqual(store.interval, .fiveSeconds)
        XCTAssertEqual(toolbarPopUp.indexOfSelectedItem, 3)

        settingsPause.performClick(nil)
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(toolbarPause.title, "Resume")
        XCTAssertEqual(settingsPause.title, "Resume Sampling")

        toolbarPause.performClick(nil)
        XCTAssertFalse(store.isPaused)
        XCTAssertEqual(settingsPause.title, "Pause Sampling")
    }

    func testSamplingTitlesUseOneFormatForToolbarFooterAndSettings() {
        XCTAssertEqual(MonitoringInterval.allCases.map(SamplingControls.seconds), ["0.5", "1", "2", "5"])
        XCTAssertEqual(SamplingControls.shortTitle(.halfSecond), "0.5 s")
        XCTAssertEqual(SamplingControls.shortTitle(.fiveSeconds), "5 s")
        XCTAssertEqual(SamplingControls.longTitle(.halfSecond), "0.5 seconds")
        XCTAssertEqual(SamplingControls.longTitle(.oneSecond), "1 second")
    }

    private func makeController(store: MutablePerformanceMonitoringStore) -> PerformanceViewController {
        let dependencies = PageDependencies(monitoringStore: store,
                                            processActions: UnusedProcessActioner(),
                                            integrations: UnavailableSystemIntegrationAPI(),
                                            fixtureMode: false)
        let controller = PerformanceViewController(dependencies: dependencies)
        controller.loadViewIfNeeded()
        controller.view.setFrameSize(NSSize(width: 960, height: 600))
        return controller
    }

    private func reading(_ value: Double, _ timestamp: Date) -> MetricReading {
        MetricReading(value: value, unit: .bytesPerSecond, timestamp: timestamp)
    }

    private func unavailableReading(_ timestamp: Date, _ detail: String) -> MetricReading {
        MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp,
                      reason: .permissionDenied, detail: detail)
    }

    private func throughputSnapshot(timestamp: Date, diskRead: MetricReading, diskWrite: MetricReading,
                                    networkReceive: MetricReading, networkSend: MetricReading) -> MonitoringSnapshot {
        let base = CoreTestFixtures.snapshot(timestamp: timestamp)
        let original = base.system
        let system = SystemMetricsSnapshot(
            capacityCores: original.capacityCores, cpuPercent: original.cpuPercent,
            perCoreCPUPercent: original.perCoreCPUPercent,
            memoryUsedBytes: original.memoryUsedBytes, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: original.memoryTotalBytes, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: diskRead, diskWriteBytesPerSecond: diskWrite,
            networkReceiveBytesPerSecond: networkReceive, networkTransmitBytesPerSecond: networkSend,
            networkInterfaces: original.networkInterfaces)
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: base.processes,
                                  processGroups: base.processGroups, startupItems: base.startupItems,
                                  services: base.services, users: base.users,
                                  discoveryCoverage: base.discoveryCoverage, capabilities: base.capabilities,
                                  advancedMetrics: base.advancedMetrics, history: base.history,
                                  applicationHistory: base.applicationHistory)
    }

    func testNearestIndexPicksClosestPositionAndHandlesEmptyAndNonFinite() {
        let positions: [CGFloat] = [10, 20, 30]
        XCTAssertEqual(MetricGraphView.nearestIndex(toX: 21, in: positions), 1)
        XCTAssertEqual(MetricGraphView.nearestIndex(toX: 0, in: positions), 0)
        XCTAssertEqual(MetricGraphView.nearestIndex(toX: 100, in: positions), 2)
        XCTAssertEqual(MetricGraphView.nearestIndex(toX: 15, in: positions), 0, "a tie keeps the earlier position")
        XCTAssertNil(MetricGraphView.nearestIndex(toX: 15, in: []))
        XCTAssertNil(MetricGraphView.nearestIndex(toX: .nan, in: positions))
    }

    func testHoverReadoutLinesCoverAvailablePartialUnavailableAndGap() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let time = UIFormat.time(timestamp)
        let available = MetricReading(value: 42, unit: .percent, timestamp: timestamp)
        let partial = MetricReading(value: 1_000, unit: .bytesPerSecond, timestamp: timestamp,
                                    detail: "2 of 3 interfaces", isPartial: true)
        let denied = MetricReading(unavailable: .percent, timestamp: timestamp, reason: .permissionDenied)
        let gap = MetricReading(unavailable: .bytesPerSecond, timestamp: timestamp, reason: .sleepGap)

        let mixed = MetricGraphView.readoutLines(series: [
            MetricGraphSeries(name: "Read", color: .systemGreen, readings: [available]),
            MetricGraphSeries(name: "Write", color: .systemGreen, readings: [partial], isSecondary: true)
        ], index: 0)
        XCTAssertEqual(mixed, [time, "Read  \(UIFormat.metric(available))", "Write  \(UIFormat.metric(partial))"])
        XCTAssertTrue(mixed[2].contains("partial"), "a partial reading says so in the readout")

        let unavailable = MetricGraphView.readoutLines(
            series: [MetricGraphSeries(name: "CPU", color: .systemBlue, readings: [denied])], index: 0)
        XCTAssertEqual(unavailable, [time, "CPU  Permission denied"])

        let sleepGap = MetricGraphView.readoutLines(
            series: [MetricGraphSeries(name: "Write", color: .systemGreen, readings: [gap])], index: 0)
        XCTAssertEqual(sleepGap, [time, "Write  Sample gap"])

        XCTAssertEqual(MetricGraphView.readoutLines(series: [MetricGraphSeries(name: "CPU", color: .systemBlue,
                                                                               readings: [available])], index: 1), [],
                       "an index past the newest sample has no readout")
    }

    func testHoverTracksOnlyDetailAndCompactGraphsAndClearsOutsideThePlot() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let readings = (0..<5).map { MetricReading(value: Double($0 * 10), unit: .percent,
                                                   timestamp: timestamp.addingTimeInterval(Double($0))) }
        let series = [MetricGraphSeries(name: "CPU", color: .systemBlue, readings: readings)]

        let detail = MetricGraphView(style: .detail)
        detail.setFrameSize(NSSize(width: 480, height: 240))
        detail.update(series: series, mapping: .index(capacity: 60))
        detail.updateTrackingAreas()
        XCTAssertEqual(detail.trackingAreas.count, 1)
        let options = detail.trackingAreas.first?.options ?? []
        XCTAssertTrue(options.contains([.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]))

        detail.setHover(x: detail.bounds.midX)
        XCTAssertEqual(detail.hoverX, detail.bounds.midX)
        detail.setHover(x: -50)
        XCTAssertNil(detail.hoverX, "a pointer outside the plot clears the readout")
        detail.setHover(x: detail.bounds.midX)
        detail.setHover(x: nil)
        XCTAssertNil(detail.hoverX, "mouse exit clears the readout")

        let sparkline = MetricGraphView(style: .sparkline)
        sparkline.setFrameSize(NSSize(width: 200, height: 30))
        sparkline.update(series: series, mapping: .index(capacity: 60))
        sparkline.updateTrackingAreas()
        XCTAssertTrue(sparkline.trackingAreas.isEmpty, "sparklines never track the pointer")
        sparkline.setHover(x: sparkline.bounds.midX)
        XCTAssertNil(sparkline.hoverX)
    }

    func testHoverReadoutKeepsItsPositionWhenDataUpdatesAndDrawsAtTheRightEdge() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        func series(_ count: Int) -> [MetricGraphSeries] {
            [MetricGraphSeries(name: "CPU", color: .systemBlue, readings: (0..<count).map { offset in
                MetricReading(value: Double(offset), unit: .percent, timestamp: timestamp.addingTimeInterval(Double(offset)))
            })]
        }
        let graph = MetricGraphView(style: .detail)
        graph.setFrameSize(NSSize(width: 480, height: 240))
        graph.update(series: series(5), mapping: .index(capacity: 60))
        let cursor = graph.bounds.maxX - 14
        graph.setHover(x: cursor)
        graph.update(series: series(6), mapping: .index(capacity: 60))
        XCTAssertEqual(graph.hoverX, cursor, "live data keeps the readout where the pointer is")

        // Near the right edge the box flips left of the cursor; drawing must stay inside the bitmap without trapping.
        let rep = try XCTUnwrap(graph.bitmapImageRepForCachingDisplay(in: graph.bounds))
        graph.cacheDisplay(in: graph.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testGraphLegendShowsOnlyForTwoSeriesMetrics() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = throughputSnapshot(
            timestamp: timestamp,
            diskRead: reading(1_024, timestamp), diskWrite: reading(2_048, timestamp),
            networkReceive: reading(4_096, timestamp), networkSend: reading(8_192, timestamp))
        let store = MutablePerformanceMonitoringStore()
        store.replace(snapshot: snapshot, samples: [MonitoringGraphSample(snapshot: snapshot)])
        let controller = makeController(store: store)
        controller.update(snapshot: snapshot)
        let legend = try XCTUnwrap(view(withIdentifier: "performance.legend", in: controller.view))

        controller.selectMetric(.cpu)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(legend.isHidden, "one series needs no legend")
        controller.selectMetric(.memory)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(legend.isHidden)

        controller.selectMetric(.disk)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(legend.isHidden)
        XCTAssertEqual(legendNames(in: legend), ["Read", "Write"])

        controller.selectMetric(.network)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(legend.isHidden)
        XCTAssertEqual(legendNames(in: legend), ["Receive", "Send"])
    }

    func testDetailCaptionAccessibilityLabelFallsBackToCaptionText() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CoreTestFixtures.snapshot(timestamp: timestamp)
        let samples = [MonitoringGraphSample(snapshot: snapshot)]
        let store = MutablePerformanceMonitoringStore()
        store.replace(snapshot: snapshot, samples: samples)
        let controller = makeController(store: store)
        controller.update(snapshot: snapshot)
        controller.selectMetric(.cpu)
        controller.view.layoutSubtreeIfNeeded()

        let expected = try XCTUnwrap(PerformancePresenter.detail(metric: .cpu, snapshot: snapshot, samples: samples,
                                                                 window: .oneMinute, cpuMode: .overall).caption)
        let caption = try XCTUnwrap(view(withIdentifier: "performance.detail.caption", in: controller.view) as? NSTextField)
        XCTAssertEqual(caption.accessibilityLabel(), expected,
                       "without a separate accessibility label the caption is its own text, not cleared")
    }

    func testWindowPickerFitsInsideItsRowAtMinimumWindowWidth() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CoreTestFixtures.snapshot(timestamp: timestamp)
        let store = MutablePerformanceMonitoringStore()
        store.replace(snapshot: snapshot, samples: [MonitoringGraphSample(snapshot: snapshot)])
        let controller = makeController(store: store)
        controller.update(snapshot: snapshot)
        controller.selectMetric(.cpu)
        controller.view.layoutSubtreeIfNeeded()

        let picker = try XCTUnwrap(view(withIdentifier: "performance.window", in: controller.view) as? NSSegmentedControl)
        XCTAssertEqual(picker.segmentCount, 4)
        XCTAssertEqual((0..<picker.segmentCount).map { picker.label(forSegment: $0) }, ["1 min", "5 min", "15 min", "1 h"])
        let row = try XCTUnwrap(picker.superview)
        row.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(picker.frame.width, 0)
        XCTAssertGreaterThanOrEqual(picker.frame.minX, row.bounds.minX)
        XCTAssertLessThanOrEqual(picker.frame.maxX, row.bounds.maxX, "the picker must not spill past its row")
        let inPage = picker.convert(picker.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(inPage.maxX, controller.view.bounds.maxX - 16)
    }

    func testPerformanceHeaderSubtitleInvitesHoverAndKeepsItsTooltip() {
        let controller = makeController(store: MutablePerformanceMonitoringStore())
        let subtitle = "Live resource use. Hover a graph to read a sample."
        let matches = allViews(in: controller.view).compactMap { $0 as? NSTextField }.filter { $0.stringValue == subtitle }
        XCTAssertEqual(matches.count, 1)
        let header = matches.first?.superview
        XCTAssertTrue(header?.toolTip?.hasPrefix("Live resource use. Gaps mark paused") == true, header?.toolTip ?? "no tooltip")
    }

    private func sectionSnapshot(perCore: [Double?], kinds: [ProcessorCoreKind]?) -> MonitoringSnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let original = CoreTestFixtures.snapshot(timestamp: timestamp).system
        let cores = perCore.map { value in
            value.map { CoreTestFixtures.reading($0, unit: .percent, timestamp: timestamp) }
                ?? MetricReading(unavailable: .percent, timestamp: timestamp, reason: .warmingUp)
        }
        let system = SystemMetricsSnapshot(
            capacityCores: cores.count, cpuPercent: original.cpuPercent, perCoreCPUPercent: cores,
            memoryUsedBytes: original.memoryUsedBytes, memoryAvailableBytes: original.memoryAvailableBytes,
            memoryTotalBytes: original.memoryTotalBytes, memoryPressure: original.memoryPressure,
            swapUsedBytes: original.swapUsedBytes, swapTotalBytes: original.swapTotalBytes,
            diskReadBytesPerSecond: original.diskReadBytesPerSecond, diskWriteBytesPerSecond: original.diskWriteBytesPerSecond,
            networkReceiveBytesPerSecond: original.networkReceiveBytesPerSecond,
            networkTransmitBytesPerSecond: original.networkTransmitBytesPerSecond,
            networkInterfaces: [],
            processorTopology: kinds.map { ProcessorTopology(kinds: $0) })
        return MonitoringSnapshot(timestamp: timestamp, system: system, processes: [], processGroups: [],
                                  startupItems: [], services: [], users: [], discoveryCoverage: [:],
                                  capabilities: [:])
    }

    private func sectionDetail(_ snapshot: MonitoringSnapshot) -> MetricDetailModel {
        PerformancePresenter.detail(metric: .cpu, snapshot: snapshot,
                                    samples: [MonitoringGraphSample(snapshot: snapshot)],
                                    window: .oneMinute, cpuMode: .logicalProcessors)
    }

    /// Compares sRGB components, so colors match by value rather than by object identity.
    private func assertSameSRGB(_ actual: NSColor, _ expected: NSColor,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs = actual.usingColorSpace(.sRGB), let rhs = expected.usingColorSpace(.sRGB) else {
            XCTFail("colors must convert to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.01, file: file, line: line)
    }

    private func legendNames(in legend: NSView) -> [String] {
        allViews(in: legend).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
        allViews(in: root).first { $0.accessibilityIdentifier() == identifier }
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }
}

/// Points `ColorPreferences` at a throwaway defaults suite for one test and puts the previous domain back on `restore()`.
@MainActor
private final class SectionColorDefaults {
    private let suite = "PerformanceSectionTests-\(UUID().uuidString)"
    private let priorOverride: UserDefaults?

    init() {
        priorOverride = ColorPreferences.defaultsOverride
        ColorPreferences.defaultsOverride = UserDefaults(suiteName: suite)
    }

    func restore() {
        ColorPreferences.defaultsOverride = priorOverride
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class MutablePerformanceMonitoringStore: MonitoringStore {
    private(set) var latestSnapshot: MonitoringSnapshot?
    private(set) var graphSamples: [MonitoringGraphSample] = []
    private(set) var interval: MonitoringInterval = .oneSecond
    private(set) var isPaused = false
    private(set) var isRunning = false
    var onSnapshot: (@MainActor @Sendable (MonitoringSnapshot) -> Void)?

    func replace(snapshot: MonitoringSnapshot, samples: [MonitoringGraphSample]) {
        latestSnapshot = snapshot
        graphSamples = samples
    }

    func start(interval: MonitoringInterval) { self.interval = interval; isRunning = true; isPaused = false }
    func setInterval(_ interval: MonitoringInterval) { self.interval = interval }
    func pause() { isPaused = true }
    func resume() { isPaused = false; isRunning = true }
    func stop() { isPaused = false; isRunning = false }
    func refreshNow() async {}
    func resetHistory() async throws {}
}

private struct UnusedProcessActioner: ProcessActioning {
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        ProcessActionResult(identity: identity, force: force,
                            outcome: .rejected(.helperUnavailable, detail: nil))
    }
}
