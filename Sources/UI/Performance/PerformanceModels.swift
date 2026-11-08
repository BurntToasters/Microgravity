import AppKit

/// Metrics listed in the Performance rail, in Task Manager order.
enum PerformanceMetric: String, CaseIterable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case energy

    var title: String {
        switch self {
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "Memory")
        case .disk: return String(localized: "Disk")
        case .network: return String(localized: "Network")
        case .gpu: return String(localized: "GPU")
        case .energy: return String(localized: "Energy")
        }
    }

    /// Hue for the rail sparkline and the detail graph. System colors only.
    var color: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .memory: return .systemPurple
        case .disk: return .systemGreen
        case .network: return .systemOrange
        case .gpu: return .systemTeal
        case .energy: return .systemYellow
        }
    }
}

/// Detail time window. Fixed windows fix the x scale; `all` scales to the retained history.
enum PerformanceWindow: CaseIterable {
    case oneMinute
    case fiveMinutes
    case all

    var title: String {
        switch self {
        case .oneMinute: return "60 s"
        case .fiveMinutes: return "5 min"
        case .all: return String(localized: "All")
        }
    }

    /// Seconds covered by the window, or nil for every retained sample.
    var duration: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .all: return nil
        }
    }
}

/// Overall CPU graph, or one mini graph per logical processor.
enum CPUDetailMode: Int {
    case overall = 0
    case logicalProcessors = 1
}

/// One rail row. `sparkline` is empty when there is nothing to draw, so the row never shows a flat zero.
struct MetricRailItem {
    let metric: PerformanceMetric
    let valueText: String
    let isValueUnavailable: Bool
    let sparkline: [MetricGraphSeries]
    let sparklineMaximum: Double?

    var accessibilityLabel: String { "\(metric.title), \(valueText)" }
}

struct DetailBanner {
    let message: String
    let style: StatusBannerView.Style
}

/// One label and value in the detail stats grid.
struct MetricStat {
    let label: String
    let value: String
    var identifier: String? = nil
    var accessibilityLabel: String? = nil
}

struct NetworkInterfaceRow {
    let name: String
    let rates: String
    let totals: String
    let membership: String
}

struct CoreTileModel {
    let index: Int
    let valueText: String
    let series: MetricGraphSeries
}

struct MemoryPressureSample {
    let timestamp: Date
    let level: MemoryPressureLevel?
    let isGap: Bool
}

struct MemoryDetailModel {
    var pressureLevel: MemoryPressureLevel?
    var pressureText = ""
    var pressureSamples: [MemoryPressureSample] = []
    var swapValue = "—"
    var swapFraction: Double?
    var swapSeries: MetricGraphSeries?
    var swapMaximum: Double?
}

/// Everything the detail card shows for one metric. Built by `PerformancePresenter`; contains no views.
struct MetricDetailModel {
    let metric: PerformanceMetric
    let window: PerformanceWindow
    let cpuMode: CPUDetailMode
    let title: String
    var subtitle: String
    var bigValue: String
    let graphIdentifier: String
    var graphAccessibilityLabel: String
    var bigValueIdentifier: String? = nil
    var isBigValueUnavailable = false
    var stateText: String? = nil
    var stateIdentifier: String? = nil
    var banner: DetailBanner? = nil
    var series: [MetricGraphSeries] = []
    var maximum: Double? = nil
    var timeSpan: TimeInterval = 60
    var spanLabel = ""
    var topLabel: String? = nil
    var caption: String? = nil
    var captionIdentifier: String? = nil
    var captionAccessibilityLabel: String? = nil
    var stats: [MetricStat] = []
    var cores: [CoreTileModel] = []
    var interfaces: [NetworkInterfaceRow] = []
    var memory: MemoryDetailModel? = nil

    init(metric: PerformanceMetric, window: PerformanceWindow, cpuMode: CPUDetailMode, title: String,
         subtitle: String, bigValue: String, graphIdentifier: String, graphAccessibilityLabel: String) {
        self.metric = metric
        self.window = window
        self.cpuMode = cpuMode
        self.title = title
        self.subtitle = subtitle
        self.bigValue = bigValue
        self.graphIdentifier = graphIdentifier
        self.graphAccessibilityLabel = graphAccessibilityLabel
    }
}

/// Turns snapshots and graph samples into rail and detail models. Pure data, so it is testable without views.
@MainActor
enum PerformancePresenter {
    static let sparklineSampleCount = 60

    static func railItems(snapshot: MonitoringSnapshot, samples: [MonitoringGraphSample]) -> [MetricRailItem] {
        let recent = Array(samples.suffix(sparklineSampleCount))
        let system = snapshot.system
        return [
            MetricRailItem(
                metric: .cpu,
                valueText: shortValue(system.cpuPercent),
                isValueUnavailable: system.cpuPercent.value == nil,
                sparkline: sparkline([series(String(localized: "CPU"), .cpu, recent.map(\.cpuPercent))]),
                sparklineMaximum: 100),
            MetricRailItem(
                metric: .memory,
                valueText: "\(shortValue(system.memoryUsedBytes)) / \(shortValue(system.memoryTotalBytes))",
                isValueUnavailable: system.memoryUsedBytes.value == nil,
                sparkline: sparkline([series(String(localized: "Used"), .memory, recent.map(\.memoryUsedBytes))]),
                sparklineMaximum: system.memoryTotalBytes.value),
            MetricRailItem(
                metric: .disk,
                valueText: throughputText((String(localized: "R"), system.diskReadBytesPerSecond), (String(localized: "W"), system.diskWriteBytesPerSecond)),
                isValueUnavailable: system.diskReadBytesPerSecond.value == nil && system.diskWriteBytesPerSecond.value == nil,
                sparkline: sparkline([
                    series(String(localized: "Read"), .disk, recent.map(\.diskReadBytesPerSecond)),
                    series(String(localized: "Write"), .disk, recent.map(\.diskWriteBytesPerSecond), secondary: true)
                ]),
                sparklineMaximum: nil),
            MetricRailItem(
                metric: .network,
                valueText: throughputText(("↓", system.networkReceiveBytesPerSecond), ("↑", system.networkTransmitBytesPerSecond)),
                isValueUnavailable: system.networkReceiveBytesPerSecond.value == nil && system.networkTransmitBytesPerSecond.value == nil,
                sparkline: sparkline([
                    series(String(localized: "Receive"), .network, recent.map(\.networkReceiveBytesPerSecond)),
                    series(String(localized: "Send"), .network, recent.map(\.networkTransmitBytesPerSecond), secondary: true)
                ]),
                sparklineMaximum: nil),
            advancedRailItem(.gpu, kind: .gpu, snapshot: snapshot, recent: recent, maximum: 100),
            advancedRailItem(.energy, kind: .energy, snapshot: snapshot, recent: recent, maximum: nil)
        ]
    }

    static func detail(metric: PerformanceMetric, snapshot: MonitoringSnapshot, samples: [MonitoringGraphSample],
                       window: PerformanceWindow, cpuMode: CPUDetailMode) -> MetricDetailModel {
        let visible = windowed(samples, window)
        let duration = spanDuration(visible)
        let span = spanText(max(duration, 1))
        var model: MetricDetailModel
        switch metric {
        case .cpu: model = cpuDetail(snapshot, visible, window, cpuMode)
        case .memory: model = memoryDetail(snapshot, visible, window, cpuMode)
        case .disk: model = diskDetail(snapshot, visible, window, cpuMode)
        case .network: model = networkDetail(snapshot, visible, window, cpuMode)
        case .gpu: model = advancedDetail(.gpu, kind: .gpu, snapshot: snapshot, visible: visible, window: window, cpuMode: cpuMode)
        case .energy: model = advancedDetail(.energy, kind: .energy, snapshot: snapshot, visible: visible, window: window, cpuMode: cpuMode)
        }
        model.subtitle = "\(model.subtitle) over \(span.long)"
        model.timeSpan = window.duration ?? max(duration, 1)
        model.spanLabel = span.short
        return model
    }

    /// Samples inside the window, measured back from the newest sample.
    static func windowed(_ samples: [MonitoringGraphSample], _ window: PerformanceWindow) -> [MonitoringGraphSample] {
        guard let duration = window.duration, let latest = samples.last else { return samples }
        let cutoff = latest.timestamp.addingTimeInterval(-duration)
        return samples.filter { $0.timestamp >= cutoff }
    }

    /// Real time covered by the samples, from the oldest to the newest.
    static func spanDuration(_ samples: [MonitoringGraphSample]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp.timeIntervalSince(first.timestamp))
    }

    /// "60 s" / "60 seconds" below five minutes, then minutes or hours.
    static func spanText(_ seconds: TimeInterval) -> (short: String, long: String) {
        let whole = Int(seconds.rounded())
        if whole < 300 {
            return (String(localized: "\(whole) s"), String(localized: "\(whole) \(whole == 1 ? String(localized: "second") : String(localized: "seconds"))"))
        }
        if whole < 3600 {
            let minutes = Int((Double(whole) / 60).rounded())
            return (String(localized: "\(minutes) min"), String(localized: "\(minutes) \(minutes == 1 ? String(localized: "minute") : String(localized: "minutes"))"))
        }
        let hours = Int((Double(whole) / 3600).rounded())
        return (String(localized: "\(hours) h"), String(localized: "\(hours) \(hours == 1 ? String(localized: "hour") : String(localized: "hours"))"))
    }

    static func shortValue(_ reading: MetricReading) -> String {
        UIFormat.value(reading) ?? UIFormat.unavailable(reading.unavailableReason)
    }

    static func pressureText(_ pressure: MemoryPressureSnapshot) -> String {
        switch pressure.level {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Warning")
        case .critical: return String(localized: "Critical")
        case nil: return UIFormat.unavailable(pressure.unavailableReason)
        }
    }

    /// True when the capability is reported off, or when no reading exists and no capability is reported.
    static func isUnavailable(_ kind: MetricKind, in snapshot: MonitoringSnapshot) -> Bool {
        if let availability = snapshot.capabilities[kind] { return !availability.available }
        return snapshot.advancedMetrics[kind]?.value == nil
    }

    // MARK: Rail

    private static func advancedRailItem(_ metric: PerformanceMetric, kind: MetricKind, snapshot: MonitoringSnapshot,
                                         recent: [MonitoringGraphSample], maximum: Double?) -> MetricRailItem {
        guard !isUnavailable(kind, in: snapshot) else {
            return MetricRailItem(metric: metric, valueText: String(localized: "Unavailable"), isValueUnavailable: true,
                                  sparkline: [], sparklineMaximum: nil)
        }
        let reading = snapshot.advancedMetrics[kind]
        let valueText = reading.flatMap { UIFormat.value($0) }
            ?? UIFormat.unavailable(reading?.unavailableReason ?? .warmingUp)
        let fallbackUnit = reading?.unit ?? defaultUnit(kind)
        let readings = recent.map { sample in
            sample.advancedMetrics[kind]
                ?? MetricReading(unavailable: fallbackUnit, timestamp: sample.timestamp, reason: .notCollected)
        }
        return MetricRailItem(metric: metric, valueText: valueText, isValueUnavailable: reading?.value == nil,
                              sparkline: sparkline([series(metric.title, metric, readings)]),
                              sparklineMaximum: maximum)
    }

    // MARK: Detail

    private static func cpuDetail(_ snapshot: MonitoringSnapshot, _ visible: [MonitoringGraphSample],
                                  _ window: PerformanceWindow, _ cpuMode: CPUDetailMode) -> MetricDetailModel {
        let cpu = snapshot.system.cpuPercent
        var model = MetricDetailModel(metric: .cpu, window: window, cpuMode: cpuMode, title: String(localized: "CPU"),
                                      subtitle: "% Utilization", bigValue: shortValue(cpu),
                                      graphIdentifier: "performance.graph.cpu-total",
                                      graphAccessibilityLabel: String(localized: "Total CPU usage percentage over time"))
        model.bigValueIdentifier = "performance.cpu-total.value"
        model.isBigValueUnavailable = cpu.value == nil
        model.series = [series(String(localized: "CPU"), .cpu, visible.map(\.cpuPercent))]
        model.maximum = 100
        model.topLabel = "100%"
        let logical = snapshot.system.capacityCores
        model.caption = String(localized: "Percent of total capacity across \(logical) logical processors.")
        model.stats = [
            MetricStat(label: String(localized: "Logical processors"), value: "\(logical)"),
            MetricStat(label: String(localized: "Processes"), value: "\(snapshot.processes.count)"),
            MetricStat(label: String(localized: "Uptime"), value: uptimeText())
        ]
        let coreCount = max(snapshot.system.perCoreCPUPercent.count,
                            visible.reduce(0) { max($0, $1.perCoreCPUPercent.count) })
        model.cores = (0..<coreCount).map { index in
            let readings = visible.map { sample -> MetricReading in
                guard sample.perCoreCPUPercent.indices.contains(index) else {
                    return MetricReading(unavailable: .percent, timestamp: sample.timestamp, reason: .notCollected)
                }
                return sample.perCoreCPUPercent[index]
            }
            let current = snapshot.system.perCoreCPUPercent.indices.contains(index)
                ? snapshot.system.perCoreCPUPercent[index]
                : MetricReading(unavailable: .percent, timestamp: snapshot.timestamp, reason: .notCollected)
            return CoreTileModel(index: index, valueText: shortValue(current),
                                 series: series(String(localized: "CPU \(index)"), .cpu, readings))
        }
        return model
    }

    private static func memoryDetail(_ snapshot: MonitoringSnapshot, _ visible: [MonitoringGraphSample],
                                     _ window: PerformanceWindow, _ cpuMode: CPUDetailMode) -> MetricDetailModel {
        let system = snapshot.system
        let used = system.memoryUsedBytes
        let total = system.memoryTotalBytes
        var model = MetricDetailModel(metric: .memory, window: window, cpuMode: cpuMode, title: String(localized: "Memory"),
                                      subtitle: String(localized: "Memory in use"),
                                      bigValue: "\(shortValue(used)) / \(shortValue(total))",
                                      graphIdentifier: "performance.graph.memory",
                                      graphAccessibilityLabel: String(localized: "Memory in use over time"))
        model.bigValueIdentifier = "performance.memory.value"
        model.isBigValueUnavailable = used.value == nil
        model.series = [series(String(localized: "Used"), .memory, visible.map(\.memoryUsedBytes))]
        model.maximum = total.value
        model.topLabel = total.value == nil ? nil : shortValue(total)
        model.stats = [
            MetricStat(label: String(localized: "Used"), value: shortValue(used)),
            MetricStat(label: String(localized: "Available"), value: shortValue(system.memoryAvailableBytes)),
            MetricStat(label: String(localized: "Total"), value: shortValue(total))
        ]
        var memory = MemoryDetailModel()
        memory.pressureLevel = system.memoryPressure.level
        memory.pressureText = pressureText(system.memoryPressure)
        memory.pressureSamples = visible.map { sample in
            MemoryPressureSample(timestamp: sample.timestamp, level: sample.memoryPressure.level,
                                 isGap: sample.cpuPercent.unavailableReason == .sleepGap)
        }
        memory.swapValue = "\(shortValue(system.swapUsedBytes)) / \(shortValue(system.swapTotalBytes))"
        memory.swapFraction = fraction(system.swapUsedBytes, system.swapTotalBytes)
        memory.swapSeries = series(String(localized: "Used"), .memory, visible.map(\.swapUsedBytes))
        memory.swapMaximum = system.swapTotalBytes.value
        model.memory = memory
        return model
    }

    private static func diskDetail(_ snapshot: MonitoringSnapshot, _ visible: [MonitoringGraphSample],
                                   _ window: PerformanceWindow, _ cpuMode: CPUDetailMode) -> MetricDetailModel {
        let system = snapshot.system
        let readHistory = visible.map(\.diskReadBytesPerSecond)
        let writeHistory = visible.map(\.diskWriteBytesPerSecond)
        let presentation = ThroughputGraphPresentation(
            graphName: String(localized: "Disk throughput"), subjectName: String(localized: "disk"),
            firstName: String(localized: "Read"), first: system.diskReadBytesPerSecond, firstHistory: readHistory,
            secondName: String(localized: "Write"), second: system.diskWriteBytesPerSecond, secondHistory: writeHistory)
        var model = MetricDetailModel(metric: .disk, window: window, cpuMode: cpuMode, title: String(localized: "Disk"),
                                      subtitle: String(localized: "Read and write · bytes per second"),
                                      bigValue: throughputText((String(localized: "R"), system.diskReadBytesPerSecond), (String(localized: "W"), system.diskWriteBytesPerSecond)),
                                      graphIdentifier: "performance.graph.disk",
                                      graphAccessibilityLabel: presentation.accessibilitySummary)
        model.series = [
            series(String(localized: "Read"), .disk, readHistory),
            series(String(localized: "Write"), .disk, writeHistory, secondary: true)
        ]
        applyThroughputScale(&model, presentation: presentation, readings: readHistory + writeHistory,
                             identifier: "performance.graph.disk.scale")
        model.stats = [
            MetricStat(label: String(localized: "Read"), value: UIFormat.metric(system.diskReadBytesPerSecond),
                       identifier: "performance.disk.read.value", accessibilityLabel: presentation.firstAccessibilityLabel),
            MetricStat(label: String(localized: "Write"), value: UIFormat.metric(system.diskWriteBytesPerSecond),
                       identifier: "performance.disk.write.value", accessibilityLabel: presentation.secondAccessibilityLabel)
        ]
        return model
    }

    private static func networkDetail(_ snapshot: MonitoringSnapshot, _ visible: [MonitoringGraphSample],
                                      _ window: PerformanceWindow, _ cpuMode: CPUDetailMode) -> MetricDetailModel {
        let system = snapshot.system
        let receiveHistory = visible.map(\.networkReceiveBytesPerSecond)
        let sendHistory = visible.map(\.networkTransmitBytesPerSecond)
        let presentation = ThroughputGraphPresentation(
            graphName: String(localized: "Network throughput"), subjectName: String(localized: "network"),
            firstName: String(localized: "Receive"), first: system.networkReceiveBytesPerSecond, firstHistory: receiveHistory,
            secondName: String(localized: "Send"), second: system.networkTransmitBytesPerSecond, secondHistory: sendHistory)
        var model = MetricDetailModel(metric: .network, window: window, cpuMode: cpuMode, title: String(localized: "Network"),
                                      subtitle: String(localized: "Received and sent · bytes per second"),
                                      bigValue: throughputText(("↓", system.networkReceiveBytesPerSecond), ("↑", system.networkTransmitBytesPerSecond)),
                                      graphIdentifier: "performance.graph.network",
                                      graphAccessibilityLabel: presentation.accessibilitySummary)
        model.series = [
            series(String(localized: "Receive"), .network, receiveHistory),
            series(String(localized: "Send"), .network, sendHistory, secondary: true)
        ]
        applyThroughputScale(&model, presentation: presentation, readings: receiveHistory + sendHistory,
                             identifier: "performance.graph.network.scale")
        model.stats = [
            MetricStat(label: String(localized: "Receive"), value: UIFormat.metric(system.networkReceiveBytesPerSecond),
                       identifier: "performance.network.receive.value", accessibilityLabel: presentation.firstAccessibilityLabel),
            MetricStat(label: String(localized: "Send"), value: UIFormat.metric(system.networkTransmitBytesPerSecond),
                       identifier: "performance.network.send.value", accessibilityLabel: presentation.secondAccessibilityLabel)
        ]
        model.interfaces = system.networkInterfaces.map { interface in
            NetworkInterfaceRow(
                name: interface.name,
                rates: "↓ \(shortValue(interface.receiveBytesPerSecond)) · ↑ \(shortValue(interface.transmitBytesPerSecond))",
                totals: String(localized: "Total ↓ \(shortValue(interface.receiveTotalBytes)) · ↑ \(shortValue(interface.transmitTotalBytes))"),
                membership: membership(interface))
        }
        return model
    }

    private static func advancedDetail(_ metric: PerformanceMetric, kind: MetricKind, snapshot: MonitoringSnapshot,
                                       visible: [MonitoringGraphSample], window: PerformanceWindow,
                                       cpuMode: CPUDetailMode) -> MetricDetailModel {
        let reading = snapshot.advancedMetrics[kind]
        let availability = snapshot.capabilities[kind]
        let unit = reading?.unit ?? visible.last?.advancedMetrics[kind]?.unit ?? defaultUnit(kind)
        let unavailable = isUnavailable(kind, in: snapshot)
        let current = reading ?? MetricReading(unavailable: unit, timestamp: snapshot.timestamp,
                                               reason: availability?.reason ?? .warmingUp, detail: availability?.detail)
        let readings = visible.map { sample in
            sample.advancedMetrics[kind] ?? MetricReading(unavailable: unit, timestamp: sample.timestamp,
                                                          reason: availability?.reason ?? .notCollected,
                                                          detail: availability?.detail)
        }
        let isComponentPower = kind == .energy && unit == .watts && current.value != nil
        let title = isComponentPower ? String(localized: "Estimated component power") : metric.title
        let subject = metric == .energy ? unitSubject(unit) : "% Utilization"
        var model = MetricDetailModel(metric: metric, window: window, cpuMode: cpuMode, title: title,
                                      subtitle: subject,
                                      bigValue: unavailable ? String(localized: "Unavailable") : shortValue(current),
                                      graphIdentifier: "performance.graph.\(metric.rawValue)",
                                      graphAccessibilityLabel: "\(metric.title) over time")
        model.isBigValueUnavailable = current.value == nil
        model.stateText = unavailable
            ? UIFormat.unavailable(availability?.reason)
            : UIFormat.metric(current)
        model.stateIdentifier = "performance.\(metric.rawValue).state"
        if unavailable {
            model.banner = DetailBanner(
                message: "\(UIFormat.availability(availability)). Shown as no data, never as zero.",
                style: .info)
        } else if current.isPartial {
            model.banner = DetailBanner(message: UIFormat.metric(current), style: .warning)
        }
        model.series = [series(metric.title, metric, readings)]
        model.maximum = kind == .gpu ? 100 : nil
        model.topLabel = kind == .gpu ? "100%" : maximumLabel(readings, unit: unit, timestamp: snapshot.timestamp)
        if metric == .gpu {
            model.caption = String(localized: "GPU activity is shown only when a provider reports it.")
        } else {
            model.caption = isComponentPower
                ? String(localized: "Estimated CPU + GPU + ANE component power; not total device power.")
                : String(localized: "Energy or power is shown in the source unit supplied by its provider.")
        }
        let status: String
        if unavailable {
            status = UIFormat.unavailable(availability?.reason)
        } else if current.value == nil {
            status = UIFormat.unavailable(current.unavailableReason)
        } else {
            status = String(localized: "Reporting")
        }
        model.stats = [
            MetricStat(label: String(localized: "Unit"), value: unitName(unit)),
            MetricStat(label: String(localized: "Status"), value: status),
            MetricStat(label: String(localized: "Source"), value: current.detail ?? availability?.detail ?? String(localized: "Not reported"))
        ]
        return model
    }

    // MARK: Helpers

    private static func applyThroughputScale(_ model: inout MetricDetailModel, presentation: ThroughputGraphPresentation,
                                             readings: [MetricReading], identifier: String) {
        model.maximum = presentation.graphMaximum
        let hasValues = readings.contains { $0.value != nil }
        model.topLabel = hasValues ? UIFormat.bytesPerSecond(presentation.graphMaximum) : nil
        model.caption = presentation.scaleText
        model.captionIdentifier = identifier
        model.captionAccessibilityLabel = presentation.scaleAccessibilityLabel
    }

    private static func series(_ name: String, _ metric: PerformanceMetric, _ readings: [MetricReading],
                               secondary: Bool = false) -> MetricGraphSeries {
        MetricGraphSeries(name: name, color: metric.color, readings: readings, isSecondary: secondary)
    }

    /// Keeps a sparkline only when at least one reading has a value, so an unavailable series never draws.
    private static func sparkline(_ series: [MetricGraphSeries]) -> [MetricGraphSeries] {
        series.contains { $0.readings.contains { $0.value != nil } } ? series : []
    }

    private static func throughputText(_ first: (String, MetricReading), _ second: (String, MetricReading)) -> String {
        var parts: [String] = []
        if first.1.value != nil { parts.append("\(first.0) \(shortValue(first.1))") }
        if second.1.value != nil { parts.append("\(second.0) \(shortValue(second.1))") }
        return parts.isEmpty ? shortValue(first.1) : parts.joined(separator: " · ")
    }

    private static func fraction(_ part: MetricReading, _ whole: MetricReading) -> Double? {
        guard let value = part.value, let total = whole.value, value.isFinite, total.isFinite, total > 0 else {
            return nil
        }
        return min(max(value / total, 0), 1)
    }

    private static func maximumLabel(_ readings: [MetricReading], unit: MetricUnit, timestamp: Date) -> String? {
        let values = readings.compactMap(\.value).filter { $0.isFinite && $0 >= 0 }
        guard let maximum = values.max() else { return nil }
        return UIFormat.value(MetricReading(value: maximum, unit: unit, timestamp: timestamp))
    }

    private static func membership(_ interface: NetworkInterfaceSnapshot) -> String {
        var text = interface.includedInTotals ? String(localized: "Included in system totals") : String(localized: "Excluded from system totals")
        if !interface.isUp { text += " · Down" }
        return text
    }

    private static func defaultUnit(_ kind: MetricKind) -> MetricUnit {
        kind == .energy ? .watts : .percent
    }

    private static func unitName(_ unit: MetricUnit) -> String {
        switch unit {
        case .percent: return String(localized: "Percent")
        case .bytes: return String(localized: "Bytes")
        case .bytesPerSecond: return String(localized: "Bytes per second")
        case .count: return String(localized: "Count")
        case .seconds: return String(localized: "Seconds")
        case .watts: return String(localized: "Watts")
        case .joules: return String(localized: "Joules")
        case .wattHours: return String(localized: "Watt-hours")
        }
    }

    private static func unitSubject(_ unit: MetricUnit) -> String {
        switch unit {
        case .watts: return String(localized: "Power in watts")
        case .joules: return String(localized: "Energy in joules")
        case .wattHours: return String(localized: "Energy in watt-hours")
        case .percent: return "% Utilization"
        default: return String(localized: "Provider-reported unit")
        }
    }

    private static func uptimeText() -> String {
        uptimeFormatter.string(from: ProcessInfo.processInfo.systemUptime) ?? String(localized: "Unavailable")
    }

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
