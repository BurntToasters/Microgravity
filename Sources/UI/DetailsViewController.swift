import AppKit

/// Pure helpers for the Details page, kept free of AppKit state so they can be tested directly.
enum DetailsPresentation {
    /// The outermost `.app` bundle on `executablePath`, used to pick the row icon. Nil for plain executables,
    /// which then share the generic executable icon.
    static func appBundlePath(forExecutable executablePath: String?) -> String? {
        UIText.appBundlePath(forExecutable: executablePath)
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
    private var rowIDByProcessIdentity: [ProcessIdentity: String] = [:]
    /// Last applied unavailability per optional column. Re-applied only when it changes, so a hidden column
    /// the user brought back with the header menu stays visible between snapshots.
    private var networkColumnUnavailable: Bool?
    private var gpuColumnUnavailable: Bool?
    private var processesUnavailableText: String?

    private lazy var searchItem: NSSearchToolbarItem = {
        let item = NSSearchToolbarItem(itemIdentifier: DetailsViewController.searchIdentifier)
        item.label = String(localized: "Search")
        item.paletteLabel = String(localized: "Search processes")
        item.toolTip = String(localized: "Search processes")
        let field = item.searchField
        field.placeholderString = String(localized: "Search processes")
        field.setAccessibilityIdentifier("details.search")
        field.target = self
        field.action = #selector(filterRows)
        (field.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        return item
    }()

    /// - Parameter autosaveName: Persists column layout under this name. Tests pass nil to keep defaults out of the app domain.
    init(autosaveName: String? = "Microgravity.details.columns.v2") {
        let tableParts = makeAccessibleTable(identifier: "details.table")
        table = tableParts.0
        table.setAccessibilityLabel(String(localized: "Process details"))
        scrollView = tableParts.1
        // Executable path is the last column so it alone absorbs spare width (lastColumnOnly autoresizing).
        // Fixed columns sum to 820 pt; with the 180 pt path column all ten fit in about 1000 pt.
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("name", String(localized: "Process"), width: 170),
            TableColumnSpec("pid", String(localized: "PID"), width: 56, alignment: .right),
            TableColumnSpec("owner", String(localized: "Owner"), width: 84),
            TableColumnSpec("parent", String(localized: "Parent PID"), width: 70, alignment: .right),
            TableColumnSpec("cpu", String(localized: "CPU"), width: 60, alignment: .right),
            TableColumnSpec("memory", String(localized: "Memory"), width: 80, alignment: .right),
            TableColumnSpec("disk", String(localized: "Disk R / W"), width: 128, alignment: .right),
            TableColumnSpec("network", String(localized: "Network"), width: 92, alignment: .right),
            TableColumnSpec("gpu", String(localized: "GPU"), width: 80, alignment: .right),
            TableColumnSpec("path", String(localized: "Executable path"), width: 180)
        ], autosaveName: autosaveName, showsIconsInFirstColumn: true)
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
            title: String(localized: "Details"),
            subtitle: String(localized: "Flat process inventory with owner, parent, executable path, and available resource columns.")
        )
        capability.setTextAccessibilityIdentifier("details.capability-state")
        capability.setMessage(String(localized: "Waiting for process data"), style: .info)
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
            // Cells show the number (or "—"); the reason for a partial or missing value goes to the tooltip.
            let cpu = MetricCellPresentation(process.cpuPercent)
            let memory = MetricCellPresentation(process.memoryBytes)
            let disk = MetricCellPresentation.combined([
                (label: String(localized: "R"), presentation: MetricCellPresentation(process.diskReadBytesPerSecond)),
                (label: String(localized: "W"), presentation: MetricCellPresentation(process.diskWriteBytesPerSecond))
            ])
            let networkCell = MetricCellPresentation(network)
            let gpuCell = MetricCellPresentation(gpu)
            return AccessibleTableRow(
                id: "details.process.\(process.id.pid)",
                values: [
                    process.name,
                    String(process.id.pid),
                    UIFormat.ownerName(process.ownerUID),
                    process.parentIdentity.map { String($0.pid) } ?? "—",
                    cpu.valueText,
                    memory.valueText,
                    disk.valueText,
                    networkCell.valueText,
                    gpuCell.valueText,
                    process.executablePath ?? String(localized: "Unavailable")
                ],
                sortKeys: [
                    .text(process.name),
                    .number(Double(process.id.pid)),
                    .text(UIFormat.ownerName(process.ownerUID)),
                    .numeric(process.parentIdentity.map { Double($0.pid) }),
                    .numeric(process.cpuPercent.value),
                    .numeric(process.memoryBytes.value),
                    diskSortKey,
                    .numeric(network.value),
                    .numeric(gpu.value),
                    .text(process.executablePath ?? String(localized: "Unavailable"))
                ],
                icon: AppIconProvider.icon(forBundlePath: DetailsPresentation.appBundlePath(forExecutable: process.executablePath)),
                cellDetails: [
                    nil, nil, nil, nil,
                    AccessibleTableCellDetail(cpu),
                    AccessibleTableCellDetail(memory),
                    AccessibleTableCellDetail(disk),
                    AccessibleTableCellDetail(networkCell),
                    AccessibleTableCellDetail(gpuCell),
                    nil
                ]
            )
        }
        processIdentityByRowID = Dictionary(uniqueKeysWithValues: sorted.map {
            ("details.process.\($0.id.pid)", $0.id)
        })
        rowIDByProcessIdentity = Dictionary(uniqueKeysWithValues: sorted.map {
            ($0.id, "details.process.\($0.id.pid)")
        })
        allRows = rows
        applyColumnVisibility(networkUnavailable: isUnavailable(networkCapability),
                              gpuUnavailable: isUnavailable(gpuCapability))

        let processAvailability = snapshot.capabilities[.processes]
        let time = UIFormat.time(snapshot.timestamp)
        if let processAvailability, !processAvailability.available {
            processesUnavailableText = UIFormat.availability(processAvailability)
            capability.clearButton()
            capability.setMessage(processesUnavailableText, style: .warning)
        } else {
            processesUnavailableText = nil
            // Per-process GPU is never collected, so it is not reported here; its column is simply hidden.
            var text = "\(sorted.count) processes · updated \(time)"
            var offersHelperSetup = false
            if isUnavailable(networkCapability) {
                if networkNeedsHelper(networkCapability) {
                    text += " · Per-process network needs the optional helper."
                    offersHelperSetup = true
                } else {
                    text += " · Network: \(UIFormat.availability(networkCapability))"
                }
            }
            // Missing optional features are information with a way forward, not a warning.
            capability.setMessage(text, style: .info)
            if offersHelperSetup {
                capability.setButton(title: String(localized: "Set Up Helper…")) {
                    NSApp.sendAction(#selector(MainWindowController.showSettings(_:)), to: nil, from: nil)
                }
            } else {
                capability.clearButton()
            }
        }
        filterRows()
    }

    /// True when the network capability is missing because the optional helper is not installed or not running.
    private func networkNeedsHelper(_ availability: MetricAvailability?) -> Bool {
        guard let availability, !availability.available else { return false }
        return availability.reason == .unsupported
            || availability.reason == .notCollected
            || availability.detail == HelperSamplingClient.unavailableError
            || availability.detail == NativeAdvancedMetricsCollector.helperRequiredDetail
    }

    /// Selects a requested process only when its PID and start time still match the current snapshot.
    func selectProcess(identity: ProcessIdentity) {
        searchItem.searchField.stringValue = ""
        filterRows()

        guard let rowID = rowIDByProcessIdentity[identity],
              let row = model.rows.firstIndex(where: { $0.id == rowID }) else {
            table.deselectAll(nil)
            selectedRowID = nil
            selectedProcessIdentity = nil
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        selectedRowID = rowID
        selectedProcessIdentity = identity
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
            model.configureEmptyState(symbolName: "exclamationmark.triangle", title: String(localized: "Processes unavailable"),
                                      caption: processesUnavailableText)
        } else if !query.isEmpty {
            model.configureEmptyState(symbolName: "magnifyingglass", title: String(localized: "No processes match \"\(query)\""),
                                      caption: String(localized: "Try a different name, path, owner, or PID."))
        } else {
            model.configureEmptyState(symbolName: "list.bullet.rectangle", title: String(localized: "No processes"),
                                      caption: String(localized: "Process discovery returned no rows."))
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
