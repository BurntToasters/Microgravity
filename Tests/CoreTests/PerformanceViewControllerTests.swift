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

    func testWindowKeepsSamplesInsideTheWindowAndNamesTheRealSpan() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0...120).map { offset in
            MonitoringGraphSample(snapshot: CoreTestFixtures.snapshot(timestamp: end.addingTimeInterval(Double(offset - 120))))
        }

        let oneMinute = PerformancePresenter.windowed(samples, .oneMinute)
        XCTAssertEqual(oneMinute.count, 61, "a 60 s window keeps the newest 60 seconds of one-second samples")
        XCTAssertEqual(PerformancePresenter.windowed(samples, .all).count, 121)
        let span = PerformancePresenter.spanText(PerformancePresenter.spanDuration(oneMinute))
        XCTAssertEqual(span.short, "60 s")
        XCTAssertEqual(span.long, "60 seconds")
        XCTAssertEqual(PerformancePresenter.spanText(300).short, "5 min")
        XCTAssertEqual(PerformancePresenter.spanText(720).long, "12 minutes")
        XCTAssertEqual(PerformancePresenter.spanText(1).long, "1 second")
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

    private func view(withIdentifier identifier: String, in root: NSView) -> NSView? {
        allViews(in: root).first { $0.accessibilityIdentifier() == identifier }
    }

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
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
