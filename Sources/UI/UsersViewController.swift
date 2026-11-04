import AppKit

@MainActor
final class UsersViewController: NSViewController, SnapshotUpdating {
    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let state = NSTextField(labelWithString: "Waiting for session data")

    init() {
        let tableParts = makeAccessibleTable(identifier: "users.table")
        table = tableParts.0
        scrollView = tableParts.1
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("user", "User", width: 190),
            TableColumnSpec("uid", "UID", width: 78, alignment: .right),
            TableColumnSpec("sessions", "Sessions", width: 230),
            TableColumnSpec("process-count", "Processes", width: 100, alignment: .right),
            TableColumnSpec("cpu", "CPU", width: 110, alignment: .right),
            TableColumnSpec("memory", "Memory", width: 130, alignment: .right)
        ])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(
            title: "Users",
            subtitle: "Active login sessions and process/resource aggregates by user. Account settings are managed by macOS."
        )
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        state.setAccessibilityIdentifier("users.discovery-state")
        let content = NSStackView(views: [header, state, scrollView])
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
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let processAvailability = snapshot.capabilities[.processes]
        let sorted = snapshot.users.sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
        let rows = sorted.map { user -> AccessibleTableRow in
            let owned = snapshot.processes.filter { $0.ownerUID == user.uid }
            let processCount: String
            if let processAvailability, !processAvailability.available {
                processCount = UIFormat.availability(processAvailability)
            } else {
                processCount = String(owned.count)
            }
            let cpu = aggregate(owned.map(\.cpuPercent), unit: .percent, capability: processAvailability)
            let memory = aggregate(owned.map(\.memoryBytes), unit: .bytes, capability: processAvailability)
            let sessionNames = user.loginSessions.isEmpty ? "No active sessions reported" : user.loginSessions.joined(separator: ", ")
            let name = user.isCurrentUser ? "\(user.shortName) (You)" : user.shortName
            return AccessibleTableRow(id: "users.row.\(slug(user.shortName))", values: [
                name,
                String(user.uid),
                sessionNames,
                processCount,
                cpu,
                memory
            ])
        }
        model.replaceRows(rows, in: table)
        if let capability = snapshot.capabilities[.userSessions], !capability.available {
            state.stringValue = UIFormat.availability(capability)
        } else {
            state.stringValue = "\(sorted.count) user records · updated \(UIFormat.time(snapshot.timestamp))"
        }
    }

    private func aggregate(_ readings: [MetricReading], unit: MetricUnit,
                           capability: MetricAvailability?) -> String {
        if let capability, !capability.available { return UIFormat.availability(capability) }
        guard !readings.isEmpty else {
            return capability?.available == true ? "0" : UIFormat.availability(capability)
        }
        let available = readings.compactMap(\.value).filter(\.isFinite)
        guard !available.isEmpty else {
            let reason = readings.first(where: { $0.value == nil })?.unavailableReason
            return UIFormat.unavailable(reason)
        }
        let value = UIFormat.metric(MetricReading(value: available.reduce(0, +), unit: unit, timestamp: Date()))
        return available.count == readings.count ? value : "Partial · \(value)"
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }
}
