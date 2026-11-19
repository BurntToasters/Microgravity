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

    /// Login-session users plus every other account that owns a process (root, `_windowserver`, …), so the
    /// Users page accounts for every listed process. Accounts without a login session have no sessions.
    static func users(sessions: [UserSessionSnapshot], processOwners: Set<UInt32>,
                      name: (UInt32) -> String) -> [UserSessionSnapshot] {
        let known = Set(sessions.map(\.uid))
        let owners = processOwners.subtracting(known).sorted().map { uid in
            UserSessionSnapshot(uid: uid, shortName: name(uid), isCurrentUser: false, loginSessions: [])
        }
        return sessions + owners
    }

    /// Badge displayed beside the user's name. The name value and sort key stay unchanged.
    static func currentUserBadge(isCurrentUser: Bool) -> String? {
        isCurrentUser ? String(localized: "You") : nil
    }
}

@MainActor
final class UsersViewController: NSViewController, SnapshotUpdating, PageToolbarProviding, NSSearchFieldDelegate {
    private static let searchIdentifier = NSToolbarItem.Identifier("users.toolbar.search")

    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let state = StatusBannerView(style: .info)
    /// One image instance for every row, so the table's diffing sees unchanged icons.
    private let userIcon: NSImage
    private var latestSnapshot: MonitoringSnapshot?
    private lazy var searchItem: NSSearchToolbarItem = {
        let item = NSSearchToolbarItem(itemIdentifier: Self.searchIdentifier)
        item.label = String(localized: "Search")
        item.paletteLabel = String(localized: "Search users")
        item.toolTip = String(localized: "Filter users by name, UID, or session")
        item.preferredWidthForSearchField = 200
        let field = item.searchField
        field.placeholderString = String(localized: "Search users")
        field.setAccessibilityIdentifier("users.search")
        field.delegate = self
        (field.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        return item
    }()

    init() {
        let tableParts = makeAccessibleTable(identifier: "users.table")
        table = tableParts.0
        table.setAccessibilityLabel(String(localized: "Users"))
        scrollView = tableParts.1
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("user", String(localized: "User"), width: 220),
            TableColumnSpec("uid", String(localized: "UID"), width: 78, alignment: .right),
            TableColumnSpec("sessions", String(localized: "Sessions"), width: 230),
            TableColumnSpec("process-count", String(localized: "Processes"), width: 100, alignment: .right),
            TableColumnSpec("cpu", String(localized: "CPU"), width: 110, alignment: .right),
            TableColumnSpec("memory", String(localized: "Memory"), width: 130, alignment: .right)
        ], showsIconsInFirstColumn: true)
        userIcon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            ?? NSImage()
        super.init(nibName: nil, bundle: nil)
        model.configureEmptyState(symbolName: "person.2", title: String(localized: "No user sessions"),
                                  caption: String(localized: "Discovery has not reported any users yet."))
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: String(localized: "Users"),
            subtitle: String(localized: "Active login sessions and process/resource aggregates by user. Account settings are managed by macOS.")
        )
        state.setTextAccessibilityIdentifier("users.discovery-state")
        state.setMessage(String(localized: "Waiting for session data"), style: .info)
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

    var toolbarItemIdentifiers: [NSToolbarItem.Identifier] { [Self.searchIdentifier] }

    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        identifier == Self.searchIdentifier ? searchItem : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        if let snapshot = latestSnapshot {
            update(snapshot: snapshot)
        }
    }

    func update(snapshot: MonitoringSnapshot) {
        latestSnapshot = snapshot
        let processAvailability = snapshot.capabilities[.processes]
        let processesByUID = UserAggregation.processesByUID(snapshot.processes)
        let query = searchItem.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = UserAggregation.users(sessions: snapshot.users, processOwners: Set(processesByUID.keys),
                                           name: { UIFormat.ownerName($0) })
            .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            .filter { user in
                guard !query.isEmpty else { return true }
                return user.shortName.localizedCaseInsensitiveContains(query)
                    || String(user.uid).localizedCaseInsensitiveContains(query)
                    || user.loginSessions.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        let userSlugCounts = Dictionary(grouping: sorted, by: { slug($0.shortName) }).mapValues(\.count)
        let timestamp = snapshot.timestamp
        let rows = sorted.map { user -> AccessibleTableRow in
            let owned = processesByUID[user.uid] ?? []
            let processCount: MetricCellPresentation
            if let processAvailability, !processAvailability.available {
                processCount = MetricCellPresentation.unavailable(processAvailability)
            } else {
                processCount = MetricCellPresentation(MetricReading(value: Double(owned.count), unit: .count, timestamp: timestamp))
            }
            let cpu = aggregate(owned.map(\.cpuPercent), unit: .percent, capability: processAvailability, timestamp: timestamp)
            let memory = aggregate(owned.map(\.memoryBytes), unit: .bytes, capability: processAvailability, timestamp: timestamp)
            let sessionNames = user.loginSessions.isEmpty ? String(localized: "No active sessions reported") : user.loginSessions.joined(separator: ", ")
            let duplicateSuffix = (userSlugCounts[slug(user.shortName)] ?? 0) > 1 ? ".uid.\(user.uid)" : ""
            return AccessibleTableRow(
                id: "users.row.\(slug(user.shortName))\(duplicateSuffix)",
                values: [user.shortName, String(user.uid), sessionNames,
                         processCount.valueText, cpu.valueText, memory.valueText],
                sortKeys: [
                    .text(user.shortName),
                    .number(Double(user.uid)),
                    .text(sessionNames),
                    processAvailability?.available == false ? .none : .number(Double(owned.count)),
                    aggregateSortKey(owned.map(\.cpuPercent), capability: processAvailability),
                    aggregateSortKey(owned.map(\.memoryBytes), capability: processAvailability)
                ],
                icon: userIcon,
                badge: UserAggregation.currentUserBadge(isCurrentUser: user.isCurrentUser),
                cellDetails: [
                    nil, nil, nil,
                    AccessibleTableCellDetail(processCount),
                    AccessibleTableCellDetail(cpu),
                    AccessibleTableCellDetail(memory)
                ]
            )
        }
        model.replaceRows(rows, in: table)
        let emptyTitle = query.isEmpty
            ? String(localized: "No user sessions")
            : String(localized: "No users match “\(query)”")
        model.configureEmptyState(symbolName: query.isEmpty ? "person.2" : "magnifyingglass",
                                  title: emptyTitle,
                                  caption: emptyCaption(snapshot: snapshot, query: query))
        // Only missing session or process data is a problem worth a warning; a normal listing is information.
        if let capability = snapshot.capabilities[.userSessions], !capability.available {
            state.setMessage(UIFormat.availability(capability), style: .warning)
        } else if let capability = snapshot.capabilities[.processes], !capability.available {
            state.setMessage(String(localized: "Process data unavailable · ") + UIFormat.availability(capability), style: .warning)
        } else {
            let noun = sorted.count == 1 ? String(localized: "user record") : String(localized: "user records")
            let updatedTime = UIFormat.time(snapshot.timestamp)
            state.setMessage(String(localized: "\(sorted.count) \(noun) · updated \(updatedTime)"), style: .info)
        }
    }

    private func emptyCaption(snapshot: MonitoringSnapshot, query: String) -> String {
        if let capability = snapshot.capabilities[.userSessions], !capability.available {
            return UIFormat.availability(capability)
        }
        if !query.isEmpty {
            return String(localized: "Try a different user name, UID, or session.")
        }
        return String(localized: "Discovery reported no user records.")
    }

    /// Sum of one user's readings. A user with no processes shows a measured zero with its unit, not a bare "0".
    private func aggregate(_ readings: [MetricReading], unit: MetricUnit, capability: MetricAvailability?,
                           timestamp: Date) -> MetricCellPresentation {
        if let capability, !capability.available { return MetricCellPresentation.unavailable(capability) }
        guard !readings.isEmpty else {
            guard capability?.available == true else {
                return MetricCellPresentation.unavailable(reason: .notCollected, detail: String(localized: "capability not reported"))
            }
            return MetricCellPresentation(MetricReading(value: 0, unit: unit, timestamp: timestamp))
        }
        return MetricCellPresentation(SystemMonitorCollector.combineRates(readings, unit: unit, timestamp: timestamp))
    }

    private func aggregateSortKey(_ readings: [MetricReading], capability: MetricAvailability?) -> ComparableSortKey {
        if capability?.available == false { return .none }
        if readings.isEmpty { return capability?.available == true ? .number(0) : .none }
        let available = readings.compactMap(\.value).filter(\.isFinite)
        return .numeric(available.isEmpty ? nil : available.reduce(0, +))
    }

    private func slug(_ value: String) -> String {
        UIText.slug(value)
    }
}
