import AppKit

@MainActor
final class DetailsViewController: NSViewController, SnapshotUpdating {
    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let search = NSSearchField()
    private var allRows: [AccessibleTableRow] = []
    private let capability = NSTextField(labelWithString: "Waiting for process data")

    init() {
        let tableParts = makeAccessibleTable(identifier: "details.table")
        table = tableParts.0
        scrollView = tableParts.1
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("name", "Process", width: 190),
            TableColumnSpec("pid", "PID", width: 70, alignment: .right),
            TableColumnSpec("owner", "Owner", width: 110),
            TableColumnSpec("parent", "Parent PID", width: 88, alignment: .right),
            TableColumnSpec("path", "Executable path", width: 280),
            TableColumnSpec("cpu", "CPU", width: 84, alignment: .right),
            TableColumnSpec("memory", "Memory", width: 105, alignment: .right),
            TableColumnSpec("disk", "Disk R / W", width: 155, alignment: .right),
            TableColumnSpec("network", "Network", width: 125, alignment: .right),
            TableColumnSpec("gpu", "GPU", width: 110, alignment: .right)
        ])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Details",
            subtitle: "Flat process inventory with owner, parent, executable path, and available resource columns."
        )
        capability.font = .systemFont(ofSize: 11)
        capability.textColor = .secondaryLabelColor
        capability.setAccessibilityIdentifier("details.capability-state")

        search.placeholderString = "Search processes"
        search.setAccessibilityIdentifier("details.search")
        search.target = self
        search.action = #selector(filterRows)
        (search.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        model.onSortChanged = { [weak self] in self?.filterRows() }
        let content = NSStackView(views: [header, capability, search, scrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
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
                unavailable: .percent,
                timestamp: snapshot.timestamp,
                reason: gpuCapability?.reason ?? .notCollected,
                detail: gpuCapability?.detail
            )
            return AccessibleTableRow(id: "details.process.\(process.id.pid)", values: [
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
            ])
        }
        allRows = rows
        filterRows()
        let processAvailability = snapshot.capabilities[.processes]
        if let processAvailability, !processAvailability.available {
            capability.stringValue = UIFormat.availability(processAvailability)
        } else {
            capability.stringValue = "\(sorted.count) processes · updated \(UIFormat.time(snapshot.timestamp))"
        }
    }
    @objc private func filterRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = allRows.filter { row in
            query.isEmpty || row.values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        if let descriptor = table.sortDescriptors.first,
           let key = descriptor.key,
           let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }) {
            rows.sort { left, right in
                let comparison = left.values[index].localizedStandardCompare(right.values[index])
                if comparison == .orderedSame { return left.id < right.id }
                return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        model.replaceRows(rows, in: table)
    }

}
