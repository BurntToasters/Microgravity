import AppKit

@MainActor
final class HistoryViewController: NSViewController, SnapshotUpdating {
    private let dependencies: PageDependencies
    private var totalsTable: NSTableView!
    private var dailyTable: NSTableView!
    private var totalsModel: AccessibleTableModel!
    private var dailyModel: AccessibleTableModel!
    private let capability = NSTextField(labelWithString: "Waiting for history")

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "App History",
            subtitle: "Measured per-app CPU, disk, and network totals from the last 30 days. Gaps and counter resets stay visible."
        )
        let range = UIComponents.label("Last 30 days", size: 12, weight: .semibold)
        range.setAccessibilityIdentifier("history.range.30-days")
        capability.font = .systemFont(ofSize: 11)
        capability.textColor = .secondaryLabelColor
        capability.setAccessibilityIdentifier("history.capability-state")
        let resetButton = NSButton(title: "Reset History…", target: self, action: #selector(confirmReset))
        resetButton.setAccessibilityIdentifier("history.action.reset")

        let (totalsTable, totalsScroll) = makeAccessibleTable(identifier: "history.table")
        self.totalsTable = totalsTable
        totalsModel = AccessibleTableModel(table: totalsTable, columns: [
            TableColumnSpec("application", "Application", width: 220),
            TableColumnSpec("cpu", "CPU time", width: 120, alignment: .right),
            TableColumnSpec("disk-read", "Disk read", width: 120, alignment: .right),
            TableColumnSpec("disk-write", "Disk write", width: 120, alignment: .right),
            TableColumnSpec("network-receive", "Network received", width: 138, alignment: .right),
            TableColumnSpec("network-transmit", "Network sent", width: 132, alignment: .right),
            TableColumnSpec("coverage", "Samples / gaps / resets", width: 170, alignment: .right)
        ])
        let (dailyTable, dailyScroll) = makeAccessibleTable(identifier: "history.daily-table")
        self.dailyTable = dailyTable
        dailyModel = AccessibleTableModel(table: dailyTable, columns: [
            TableColumnSpec("day", "Day", width: 130),
            TableColumnSpec("application", "Application", width: 200),
            TableColumnSpec("cpu", "CPU time", width: 120, alignment: .right),
            TableColumnSpec("disk-read", "Disk read", width: 120, alignment: .right),
            TableColumnSpec("disk-write", "Disk write", width: 120, alignment: .right),
            TableColumnSpec("network", "Network", width: 150, alignment: .right),
            TableColumnSpec("coverage", "Samples / gaps / resets", width: 170, alignment: .right)
        ])

        let totalsHeader = NSStackView(views: [UIComponents.label("30-day totals", size: 14, weight: .semibold), NSView(), range])
        totalsHeader.orientation = .horizontal
        totalsHeader.alignment = .centerY
        let dailyHeader = NSStackView(views: [UIComponents.label("Daily detail", size: 14, weight: .semibold), NSView(), capability, resetButton])
        dailyHeader.orientation = .horizontal
        dailyHeader.alignment = .centerY
        dailyHeader.spacing = 12
        let content = NSStackView(views: [header, totalsHeader, totalsScroll, dailyHeader, dailyScroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        totalsScroll.translatesAutoresizingMaskIntoConstraints = false
        dailyScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            totalsScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            dailyScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            totalsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            dailyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            totalsHeader.widthAnchor.constraint(equalTo: content.widthAnchor),
            dailyHeader.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let cutoff = snapshot.timestamp.addingTimeInterval(-29 * 86_400)
        let lastThirtyDays = snapshot.applicationHistory.filter { $0.dayStart >= cutoff && $0.dayStart <= snapshot.timestamp }
        let byApplication = Dictionary(grouping: lastThirtyDays, by: { $0.application.id })
        let applications = byApplication.values.compactMap { $0.first?.application }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let applicationSlugCounts = Dictionary(grouping: applications, by: { slug($0.name) }).mapValues(\.count)
        let totalRows = applications.map { application -> AccessibleTableRow in
            let records = byApplication[application.id] ?? []
            let gaps = records.reduce(0) { $0 + $1.gaps }
            let resets = records.reduce(0) { $0 + $1.counterResets }
            let samples = records.reduce(0) { $0 + $1.sampleCount }
            let applicationSlug = slug(application.name)
            let duplicateSuffix = (applicationSlugCounts[applicationSlug] ?? 0) > 1 ? ".application.\(application.id)" : ""
            let rowID = "history.total.\(applicationSlug)\(duplicateSuffix)"
            let cpuValues = records.map(\.cpuSeconds)
            let diskReadValues = records.map { $0.diskReadBytes.map(Double.init) }
            let diskWriteValues = records.map { $0.diskWriteBytes.map(Double.init) }
            let networkReceiveValues = records.map { $0.networkReceiveBytes.map(Double.init) }
            let networkTransmitValues = records.map { $0.networkTransmitBytes.map(Double.init) }
            return AccessibleTableRow(
                id: rowID,
                values: [
                    application.name,
                    total(cpuValues, unit: .seconds, gapCount: gaps),
                    total(diskReadValues, unit: .bytes, gapCount: gaps),
                    total(diskWriteValues, unit: .bytes, gapCount: gaps),
                    total(networkReceiveValues, unit: .bytes, gapCount: gaps),
                    total(networkTransmitValues, unit: .bytes, gapCount: gaps),
                    "\(samples) / \(gaps) / \(resets)"
                ],
                sortKeys: [
                    .text(application.name),
                    sortTotal(cpuValues),
                    sortTotal(diskReadValues),
                    sortTotal(diskWriteValues),
                    sortTotal(networkReceiveValues),
                    sortTotal(networkTransmitValues),
                    .number(Double(samples))
                ]
            )
        }
        totalsModel.replaceRows(totalRows, in: totalsTable)

        let formatter = Self.dayFormatter
        let dailyRows = lastThirtyDays.sorted {
            if $0.dayStart != $1.dayStart { return $0.dayStart > $1.dayStart }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }.map { item -> AccessibleTableRow in
            let day = formatter.string(from: item.dayStart)
            let applicationSlug = slug(item.application.name)
            let duplicateSuffix = (applicationSlugCounts[applicationSlug] ?? 0) > 1 ? ".application.\(item.application.id)" : ""
            let rowID = item.gaps > 0
                ? "history.gap.\(day).\(applicationSlug)\(duplicateSuffix)"
                : "history.day.\(day).\(applicationSlug)\(duplicateSuffix)"
            let diskRead = item.diskReadBytes.map(Double.init)
            let diskWrite = item.diskWriteBytes.map(Double.init)
            let networkValues = [item.networkReceiveBytes, item.networkTransmitBytes].compactMap { $0.map(Double.init) }
            return AccessibleTableRow(
                id: rowID,
                values: [
                    day,
                    item.application.name,
                    dailyValue(item.cpuSeconds, unit: .seconds, gaps: item.gaps),
                    dailyValue(diskRead, unit: .bytes, gaps: item.gaps),
                    dailyValue(diskWrite, unit: .bytes, gaps: item.gaps),
                    "R \(dailyValue(item.networkReceiveBytes.map(Double.init), unit: .bytes, gaps: item.gaps)) · S \(dailyValue(item.networkTransmitBytes.map(Double.init), unit: .bytes, gaps: item.gaps))",
                    "\(item.sampleCount) / \(item.gaps) / \(item.counterResets)"
                ],
                sortKeys: [
                    .number(item.dayStart.timeIntervalSince1970),
                    .text(item.application.name),
                    .numeric(item.cpuSeconds),
                    .numeric(diskRead),
                    .numeric(diskWrite),
                    .numeric(networkValues.isEmpty ? nil : networkValues.reduce(0, +)),
                    .number(Double(item.sampleCount))
                ]
            )
        }
        dailyModel.replaceRows(dailyRows, in: dailyTable)
        let availability = snapshot.capabilities[.history]
        if let availability, !availability.available {
            capability.stringValue = UIFormat.availability(availability)
        } else {
            capability.stringValue = "\(applications.count) applications · updated \(UIFormat.time(snapshot.timestamp))"
        }
    }

    @objc private func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset App History"
        alert.informativeText = "This clears Microgravity’s stored 30-day aggregate history. It does not change process or operating-system state."
        alert.addButton(withTitle: "Reset History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await dependencies.monitoringStore.resetHistory()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func total(_ values: [Double?], unit: MetricUnit, gapCount: Int) -> String {
        let present = values.compactMap { $0 }.filter { $0.isFinite }
        guard !present.isEmpty else { return gapCount > 0 ? "Unavailable · \(gapCount) gap(s)" : "Unavailable" }
        let reading = MetricReading(value: present.reduce(0, +), unit: unit, timestamp: Date())
        let value = UIFormat.metric(reading)
        return values.contains(where: { $0 == nil }) || gapCount > 0 ? "Measured \(value) · partial" : value
    }

    private func dailyValue(_ value: Double?, unit: MetricUnit, gaps: Int) -> String {
        guard let value else { return gaps > 0 ? "Missing · \(gaps) gap(s)" : "Unavailable" }
        let formatted = UIFormat.metric(MetricReading(value: value, unit: unit, timestamp: Date()))
        return gaps > 0 ? "\(formatted) · partial" : formatted
    }

    private func sortTotal(_ values: [Double?]) -> ComparableSortKey {
        let measured = values.compactMap { $0 }.filter(\.isFinite)
        return .numeric(measured.isEmpty ? nil : measured.reduce(0, +))
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "History could not be reset"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
