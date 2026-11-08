import AppKit

/// Performance page, Task Manager style: a metric rail on the left and a detail card on the right.
///
/// The page owns selection, the detail time window and the CPU view mode. Pause/Resume and the refresh interval
/// live in the window toolbar through `PageToolbarProviding`. Both write the same state Settings uses.
@MainActor
final class PerformanceViewController: NSViewController, SnapshotUpdating, PageToolbarProviding {
    static let pauseItemIdentifier = NSToolbarItem.Identifier("Microgravity.performance.pause")
    static let refreshItemIdentifier = NSToolbarItem.Identifier("Microgravity.performance.refreshInterval")

    private let dependencies: PageDependencies
    private let rail = MetricRailView()
    private let detail = MetricDetailViewController()
    private let pauseButton = NSButton(title: String(localized: "Pause"), target: nil, action: nil)
    private let refreshPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var pauseItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: PerformanceViewController.pauseItemIdentifier)
        item.view = self.pauseButton
        item.label = String(localized: "Pause")
        item.paletteLabel = String(localized: "Pause Sampling")
        item.toolTip = String(localized: "Pause or resume sampling")
        return item
    }()
    private lazy var refreshItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: PerformanceViewController.refreshItemIdentifier)
        item.view = self.refreshPopUp
        item.label = String(localized: "Refresh Interval")
        item.paletteLabel = String(localized: "Refresh Interval")
        item.toolTip = String(localized: "How often Microgravity samples the system")
        return item
    }()

    private var snapshot: MonitoringSnapshot?
    private(set) var selectedMetric: PerformanceMetric = .cpu
    private(set) var detailWindow: PerformanceWindow = .oneMinute
    private(set) var cpuMode: CPUDetailMode = .overall

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
        pauseButton.target = self
        pauseButton.action = #selector(toggleSampling)
        pauseButton.bezelStyle = .toolbar
        pauseButton.setAccessibilityIdentifier("performance.action.pause")
        refreshPopUp.addItems(withTitles: MonitoringInterval.allCases.map(SamplingControls.shortTitle))
        refreshPopUp.target = self
        refreshPopUp.action = #selector(changeRefreshInterval(_:))
        refreshPopUp.setAccessibilityIdentifier("performance.refresh-interval")
        refreshPopUp.setAccessibilityLabel(String(localized: "Refresh interval"))
        refreshPopUp.toolTip = String(localized: "How often Microgravity samples the system")
        // Settings and the sidebar footer change sampling too; keep the toolbar in step without waiting for a snapshot.
        NotificationCenter.default.addObserver(self, selector: #selector(samplingStateChanged),
                                               name: .samplingStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let page = DynamicWindowBackgroundView()
        view = page

        let header = UIComponents.header(title: String(localized: "Performance"), subtitle: "")
        header.toolTip = String(localized: "Live resource use. Gaps mark paused or missed samples; unavailable metrics are never drawn as zero.")
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.onSelect = { [weak self] metric in self?.selectMetric(metric) }
        detail.onWindowChange = { [weak self] window in
            self?.detailWindow = window
            self?.rerender()
        }
        detail.onCPUModeChange = { [weak self] mode in self?.setCPUMode(mode) }
        addChild(detail)
        detail.view.translatesAutoresizingMaskIntoConstraints = false

        page.addSubview(header)
        page.addSubview(rail)
        page.addSubview(detail.view)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: PageLayout.horizontalInset),
            header.topAnchor.constraint(equalTo: page.topAnchor, constant: PageLayout.topInset),
            rail.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: PageLayout.horizontalInset),
            rail.topAnchor.constraint(equalTo: header.bottomAnchor, constant: PageLayout.sectionSpacing),
            rail.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -PageLayout.bottomInset),
            rail.widthAnchor.constraint(equalToConstant: 240),
            detail.view.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 14),
            detail.view.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -PageLayout.horizontalInset),
            detail.view.topAnchor.constraint(equalTo: rail.topAnchor),
            detail.view.bottomAnchor.constraint(equalTo: rail.bottomAnchor)
        ])
    }

    // MARK: SnapshotUpdating

    func update(snapshot: MonitoringSnapshot) {
        self.snapshot = snapshot
        render(snapshot: snapshot)
    }

    // MARK: PageToolbarProviding

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [PerformanceViewController.pauseItemIdentifier, PerformanceViewController.refreshItemIdentifier]
    }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if identifier == PerformanceViewController.pauseItemIdentifier { return pauseItem }
        if identifier == PerformanceViewController.refreshItemIdentifier { return refreshItem }
        return nil
    }

    // MARK: Selection and modes

    /// Selects a rail metric and redraws the detail card.
    func selectMetric(_ metric: PerformanceMetric) {
        selectedMetric = metric
        rerender()
    }

    /// Switches the CPU detail between the overall graph and the per-processor grid.
    func setCPUMode(_ mode: CPUDetailMode) {
        cpuMode = mode
        rerender()
    }

    private func rerender() {
        guard let snapshot else { return }
        render(snapshot: snapshot)
    }

    private func render(snapshot: MonitoringSnapshot) {
        let samples = dependencies.monitoringStore.graphSamples
        rail.update(items: PerformancePresenter.railItems(snapshot: snapshot, samples: samples),
                    selectedMetric: selectedMetric)
        detail.update(PerformancePresenter.detail(metric: selectedMetric, snapshot: snapshot, samples: samples,
                                                  window: detailWindow, cpuMode: cpuMode))
        syncToolbar()
    }

    // MARK: Toolbar

    private func syncToolbar() {
        let store = dependencies.monitoringStore
        let title = store.isPaused ? String(localized: "Resume") : String(localized: "Pause")
        pauseButton.title = title
        pauseItem.label = title
        if let index = MonitoringInterval.allCases.firstIndex(of: store.interval) {
            refreshPopUp.selectItem(at: index)
        }
    }

    @objc private func toggleSampling() {
        SamplingControls.togglePause(store: dependencies.monitoringStore)
    }

    @objc private func changeRefreshInterval(_ sender: NSPopUpButton) {
        let intervals = MonitoringInterval.allCases
        let index = sender.indexOfSelectedItem
        guard intervals.indices.contains(index) else { return }
        SamplingControls.setInterval(intervals[index], store: dependencies.monitoringStore)
    }

    @objc private func samplingStateChanged() {
        syncToolbar()
    }
}

@MainActor
struct ThroughputGraphPresentation {
    let firstValueText: String
    let secondValueText: String
    let firstAccessibilityLabel: String
    let secondAccessibilityLabel: String
    let graphMaximum: Double
    let scaleText: String
    let scaleAccessibilityLabel: String
    let accessibilitySummary: String

    init(graphName: String, subjectName: String, firstName: String, first: MetricReading, firstHistory: [MetricReading],
         secondName: String, second: MetricReading, secondHistory: [MetricReading]) {
        firstValueText = "\(firstName): \(UIFormat.metric(first))"
        secondValueText = "\(secondName): \(UIFormat.metric(second))"
        firstAccessibilityLabel = String(localized: "Current \(subjectName) \(firstName) throughput")
        secondAccessibilityLabel = String(localized: "Current \(subjectName) \(secondName) throughput")
        scaleAccessibilityLabel = "\(graphName) graph scale maximum"

        let values = (firstHistory + secondHistory).compactMap(\.value).filter { $0.isFinite && $0 >= 0 }
        graphMaximum = Self.niceMaximum(max(values.max() ?? 1, 0.0001))
        scaleText = values.isEmpty
            ? String(localized: "Scale maximum: no data")
            : String(localized: "Scale maximum: \(UIFormat.bytesPerSecond(graphMaximum))")
        let current = String(localized: "Current \(firstName): \(UIFormat.metric(first)); current \(secondName): \(UIFormat.metric(second))")
        accessibilitySummary = values.isEmpty
            ? "\(graphName) graph. No graph samples have available data. \(current). Scale maximum: no data."
            : "\(graphName) graph. \(current). \(scaleText)."
    }

    /// Rounds `value` up to 1, 2, 5 or 10 times a power of ten. The scale label then holds still while samples
    /// move a little, instead of jittering with every new peak.
    static func niceMaximum(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        var exponent = floor(log10(value))
        // log10 can land one power of ten off near exact powers of ten, so correct it against the value.
        if pow(10, exponent + 1) <= value { exponent += 1 }
        if pow(10, exponent) > value { exponent -= 1 }
        let scale = pow(10, exponent)
        let mantissa = value / scale
        // A small tolerance keeps values such as 0.0001 from rounding up a step on floating-point error.
        let tolerance = 1e-9
        let step: Double
        if mantissa <= 1 + tolerance {
            step = 1
        } else if mantissa <= 2 + tolerance {
            step = 2
        } else if mantissa <= 5 + tolerance {
            step = 5
        } else {
            step = 10
        }
        return step * scale
    }
}
