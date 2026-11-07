import AppKit

/// Pure helpers for the Users page, kept free of AppKit so they can be tested directly.
enum UserAggregation {
    /// Processes grouped by owner UID in one pass. Build it once per snapshot and look each user up in it.
    /// Processes without an owner UID belong to no user.
    static func processesByUID(_ processes: [ProcessSnapshot]) -> [UInt32: [ProcessSnapshot]] {
        var grouped: [UInt32: [ProcessSnapshot]] = [:]
        for process in processes {
            guard let uid = process.ownerUID else { continue }
            grouped[uid, default: []].append(process)
        }
        return grouped
    }

    /// Text for the "You" column. It lives in its own column, so the name column sorts on the bare short name.
    static func currentUserMarker(isCurrentUser: Bool) -> String {
        isCurrentUser ? "You" : ""
    }
}

@MainActor
final class UsersViewController: NSViewController, SnapshotUpdating {
    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let state = StatusBannerView(style: .info)
    /// One image instance for every row, so the table's diffing sees unchanged icons.
    private let userIcon: NSImage

    init() {
        let tableParts = makeAccessibleTable(identifier: "users.table")
        table = tableParts.0
        table.setAccessibilityLabel("Users")
        scrollView = tableParts.1
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("user", "User", width: 200),
            TableColumnSpec("current", "You", width: 56),
            TableColumnSpec("uid", "UID", width: 78, alignment: .right),
            TableColumnSpec("sessions", "Sessions", width: 230),
            TableColumnSpec("process-count", "Processes", width: 100, alignment: .right),
            TableColumnSpec("cpu", "CPU", width: 110, alignment: .right),
            TableColumnSpec("memory", "Memory", width: 130, alignment: .right)
        ], showsIconsInFirstColumn: true)
        userIcon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            ?? NSImage()
        super.init(nibName: nil, bundle: nil)
        model.configureEmptyState(symbolName: "person.2", title: "No user sessions",
                                  caption: "Discovery has not reported any users yet.")
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Users",
            subtitle: "Active login sessions and process/resource aggregates by user. Account settings are managed by macOS."
        )
        state.setTextAccessibilityIdentifier("users.discovery-state")
        state.setMessage("Waiting for session data", style: .info)
        let content = NSStackView(views: [header, state, scrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate(PageLayout.pin(content, in: view) + [
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            state.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let processAvailability = snapshot.capabilities[.processes]
        let sorted = snapshot.users.sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
        let userSlugCounts = Dictionary(grouping: sorted, by: { slug($0.shortName) }).mapValues(\.count)
        let processesByUID = UserAggregation.processesByUID(snapshot.processes)
        let rows = sorted.map { user -> AccessibleTableRow in
            let owned = processesByUID[user.uid] ?? []
            let processCount: String
            if let processAvailability, !processAvailability.available {
                processCount = UIFormat.availability(processAvailability)
            } else {
                processCount = String(owned.count)
            }
            let cpu = aggregate(owned.map(\.cpuPercent), unit: .percent, capability: processAvailability)
            let memory = aggregate(owned.map(\.memoryBytes), unit: .bytes, capability: processAvailability)
            let sessionNames = user.loginSessions.isEmpty ? "No active sessions reported" : user.loginSessions.joined(separator: ", ")
            let marker = UserAggregation.currentUserMarker(isCurrentUser: user.isCurrentUser)
            let duplicateSuffix = (userSlugCounts[slug(user.shortName)] ?? 0) > 1 ? ".uid.\(user.uid)" : ""
            return AccessibleTableRow(
                id: "users.row.\(slug(user.shortName))\(duplicateSuffix)",
                values: [user.shortName, marker, String(user.uid), sessionNames, processCount, cpu, memory],
                sortKeys: [
                    .text(user.shortName),
                    .text(marker),
                    .number(Double(user.uid)),
                    .text(sessionNames),
                    processAvailability?.available == false ? .none : .number(Double(owned.count)),
                    aggregateSortKey(owned.map(\.cpuPercent), capability: processAvailability),
                    aggregateSortKey(owned.map(\.memoryBytes), capability: processAvailability)
                ],
                icon: userIcon
            )
        }
        model.replaceRows(rows, in: table)
        model.configureEmptyState(symbolName: "person.2", title: "No user sessions",
                                  caption: emptyCaption(snapshot: snapshot))
        if let capability = snapshot.capabilities[.userSessions], !capability.available {
            state.setMessage(UIFormat.availability(capability), style: .warning)
        } else {
            state.setMessage("\(sorted.count) user records · updated \(UIFormat.time(snapshot.timestamp))", style: .info)
        }
    }

    private func emptyCaption(snapshot: MonitoringSnapshot) -> String {
        if let capability = snapshot.capabilities[.userSessions], !capability.available {
            return UIFormat.availability(capability)
        }
        return "Discovery reported no user records."
    }

    private func aggregate(_ readings: [MetricReading], unit: MetricUnit,
                           capability: MetricAvailability?) -> String {
        if let capability, !capability.available { return UIFormat.availability(capability) }
        guard !readings.isEmpty else {
            return capability?.available == true ? "0" : UIFormat.availability(capability)
        }
        let aggregate = SystemMonitorCollector.combineRates(readings, unit: unit, timestamp: Date())
        return UIFormat.metric(aggregate)
    }

    private func aggregateSortKey(_ readings: [MetricReading], capability: MetricAvailability?) -> ComparableSortKey {
        if capability?.available == false { return .none }
        if readings.isEmpty { return capability?.available == true ? .number(0) : .none }
        let available = readings.compactMap(\.value).filter(\.isFinite)
        return .numeric(available.isEmpty ? nil : available.reduce(0, +))
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }
}
