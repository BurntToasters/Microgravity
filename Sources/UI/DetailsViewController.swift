import AppKit

/// Pure helpers for the Details page, kept free of AppKit state so they can be tested directly.
enum DetailsPresentation {
    /// The outermost `.app` bundle on `executablePath`, used to pick the row icon. Nil for plain executables,
    /// which then share the generic executable icon.
    static func appBundlePath(forExecutable executablePath: String?) -> String? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }
}

@MainActor
final class DetailsViewController: NSViewController, SnapshotUpdating {
    private static let searchIdentifier = NSToolbarItem.Identifier("details.search")

    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let capability = StatusBannerView(style: .info)
    private var allRows: [AccessibleTableRow] = []
    private var selectedRowID: String?
    private var selectedProcessIdentity: ProcessIdentity?
    private var processIdentityByRowID: [String: ProcessIdentity] = [:]
    /// Last applied unavailability per optional column. Re-applied only when it changes, so a hidden column
    /// the user brought back with the header menu stays visible between snapshots.
    private var networkColumnUnavailable: Bool?
    private var gpuColumnUnavailable: Bool?
    private var processesUnavailableText: String?

    private lazy var searchItem: NSSearchToolbarItem = {
        let item = NSSearchToolbarItem(itemIdentifier: DetailsViewController.searchIdentifier)
        item.label = "Search"
        item.paletteLabel = "Search processes"
        item.toolTip = "Search processes"
        let field = item.searchField
        field.placeholderString = "Search processes"
        field.setAccessibilityIdentifier("details.search")
        field.target = self
        field.action = #selector(filterRows)
        (field.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        return item
    }()

    init() {
        let tableParts = makeAccessibleTable(identifier: "details.table")
        table = tableParts.0
        table.setAccessibilityLabel("Process details")
        scrollView = tableParts.1
        // Executable path is the last column so it alone absorbs spare width (lastColumnOnly autoresizing).
        // Fixed columns sum to 820 pt; with the 180 pt path column all ten fit in about 1000 pt.
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("name", "Process", width: 170),
            TableColumnSpec("pid", "PID", width: 56, alignment: .right),
            TableColumnSpec("owner", "Owner", width: 84),
            TableColumnSpec("parent", "Parent PID", width: 70, alignment: .right),
            TableColumnSpec("cpu", "CPU", width: 60, alignment: .right),
            TableColumnSpec("memory", "Memory", width: 80, alignment: .right),
            TableColumnSpec("disk", "Disk R / W", width: 128, alignment: .right),
            TableColumnSpec("network", "Network", width: 92, alignment: .right),
            TableColumnSpec("gpu", "GPU", width: 80, alignment: .right),
            TableColumnSpec("path", "Executable path", width: 180)
        ], autosaveName: "Microgravity.details.columns.v2", showsIconsInFirstColumn: true)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.tableColumns.first { $0.identifier.rawValue == "path" }?.minWidth = 120
        super.init(nibName: nil, bundle: nil)
        model.onSelectionChanged = { [weak self] rowID in
            self?.selectedRowID = rowID
            self?.selectedProcessIdentity = rowID.flatMap { self?.processIdentityByRowID[$0] }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Details",
            subtitle: "Flat process inventory with owner, parent, executable path, and available resource columns."
        )
        capability.setTextAccessibilityIdentifier("details.capability-state")
        capability.setMessage("Waiting for process data", style: .info)
        let content = NSStackView(views: [header, capability, scrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate(PageLayout.pin(content, in: view) + [
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            capability.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            header.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let networkCapability = snapshot.capabilities[.processNetwork]
        let gpuCapability = snapshot.capabilities[.processGPUTime]
        let sorted = snapshot.processes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rows = sorted.map { process -> AccessibleTableRow in
            let network = process.advancedMetrics[.processNetwork] ?? MetricReading(
                unavailable: .bytesPerSecond,
                timestamp: snapshot.timestamp,
                reason: networkCapability?.reason ?? .notCollected,
                detail: networkCapability?.detail
            )
            let gpu = process.advancedMetrics[.processGPUTime] ?? MetricReading(
                unavailable: .seconds,
                timestamp: snapshot.timestamp,
                reason: gpuCapability?.reason ?? .notCollected,
                detail: gpuCapability?.detail
            )
            let diskValues = [process.diskReadBytesPerSecond.value, process.diskWriteBytesPerSecond.value].compactMap { $0 }
            let diskSortKey = ComparableSortKey.numeric(diskValues.isEmpty ? nil : diskValues.reduce(0, +))
            return AccessibleTableRow(
                id: "details.process.\(process.id.pid)",
                values: [
                    process.name,
                    String(process.id.pid),
                    UIFormat.ownerName(process.ownerUID),
                    process.parentIdentity.map { String($0.pid) } ?? "—",
                    process.executablePath ?? "Unavailable",
                    UIFormat.metric(process.cpuPercent),
                    UIFormat.metric(process.memoryBytes),
                    "R \(UIFormat.metric(process.diskReadBytesPerSecond)) · W \(UIFormat.metric(process.diskWriteBytesPerSecond))",
                    UIFormat.metric(network),
                    UIFormat.metric(gpu)
                ],
                sortKeys: [
                    .text(process.name),
                    .number(Double(process.id.pid)),
                    .text(UIFormat.ownerName(process.ownerUID)),
                    .numeric(process.parentIdentity.map { Double($0.pid) }),
                    .text(process.executablePath ?? "Unavailable"),
                    .numeric(process.cpuPercent.value),
                    .numeric(process.memoryBytes.value),
                    diskSortKey,
                    .numeric(network.value),
                    .numeric(gpu.value)
                ],
                icon: AppIconProvider.icon(forBundlePath: DetailsPresentation.appBundlePath(forExecutable: process.executablePath))
            )
        }
        processIdentityByRowID = Dictionary(uniqueKeysWithValues: sorted.map {
            ("details.process.\($0.id.pid)", $0.id)
        })
        allRows = rows
        applyColumnVisibility(networkUnavailable: isUnavailable(networkCapability),
                              gpuUnavailable: isUnavailable(gpuCapability))

        let processAvailability = snapshot.capabilities[.processes]
        let time = UIFormat.time(snapshot.timestamp)
        if let processAvailability, !processAvailability.available {
            processesUnavailableText = UIFormat.availability(processAvailability)
            capability.setMessage(processesUnavailableText, style: .warning)
        } else {
            processesUnavailableText = nil
            var parts = ["\(sorted.count) processes · updated \(time)"]
            if isUnavailable(networkCapability) {
                parts.append("Network: \(UIFormat.availability(networkCapability))")
            }
            if isUnavailable(gpuCapability) {
                parts.append("GPU: \(UIFormat.availability(gpuCapability))")
            }
            capability.setMessage(parts.joined(separator: " · "), style: parts.count > 1 ? .warning : .info)
        }
        filterRows()
    }

    private func isUnavailable(_ availability: MetricAvailability?) -> Bool {
        availability?.available == false
    }

    /// Hides the Network and GPU columns while their capability is unavailable; the banner still explains why.
    private func applyColumnVisibility(networkUnavailable: Bool, gpuUnavailable: Bool) {
        if networkColumnUnavailable != networkUnavailable {
            model.setColumnHidden("network", networkUnavailable)
            networkColumnUnavailable = networkUnavailable
        }
        if gpuColumnUnavailable != gpuUnavailable {
            model.setColumnHidden("gpu", gpuUnavailable)
            gpuColumnUnavailable = gpuUnavailable
        }
    }

    @objc private func filterRows() {
        let query = searchItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = allRows.filter { row in
            query.isEmpty || row.values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        updateEmptyState(query: query, matchCount: rows.count)
        let previousSelection = selectedRowID
        let previousIdentity = selectedProcessIdentity
        model.replaceRows(rows, in: table)
        if let previousSelection,
           let rowIndex = model.rows.firstIndex(where: { $0.id == previousSelection }),
           previousIdentity == nil || processIdentityByRowID[previousSelection] == previousIdentity {
            table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            selectedRowID = previousSelection
            selectedProcessIdentity = processIdentityByRowID[previousSelection]
        } else {
            table.deselectAll(nil)
            selectedRowID = nil
            selectedProcessIdentity = nil
        }
    }

    private func updateEmptyState(query: String, matchCount: Int) {
        guard matchCount == 0 else { return }
        if let processesUnavailableText {
            model.configureEmptyState(symbolName: "exclamationmark.triangle", title: "Processes unavailable",
                                      caption: processesUnavailableText)
        } else if !query.isEmpty {
            model.configureEmptyState(symbolName: "magnifyingglass", title: "No processes match \"\(query)\"",
                                      caption: "Try a different name, path, owner, or PID.")
        } else {
            model.configureEmptyState(symbolName: "list.bullet.rectangle", title: "No processes",
                                      caption: "Process discovery returned no rows.")
        }
    }
}

extension DetailsViewController: PageToolbarProviding {
    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [Self.searchIdentifier]
    }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        identifier == Self.searchIdentifier ? searchItem : nil
    }
}
