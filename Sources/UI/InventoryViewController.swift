import AppKit

enum InventoryKind {
    case startup
    case services

    var title: String {
        switch self {
        case .startup: return "Startup"
        case .services: return "Services"
        }
    }

    var coverageKey: String {
        switch self {
        case .startup: return "startupItems"
        case .services: return "services"
        }
    }

    var pageIdentifier: String {
        switch self {
        case .startup: return "startup"
        case .services: return "services"
        }
    }
}

@MainActor
final class InventoryViewController: NSViewController, SnapshotUpdating {
    private let kind: InventoryKind
    private let table: NSTableView
    private let scrollView: NSScrollView
    private let model: AccessibleTableModel
    private let dependencies: PageDependencies
    private let coverageLabel = NSTextField(labelWithString: "Waiting for discovery")
    private let selectionLabel = NSTextField(labelWithString: "Select an item to inspect its path.")
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private var entries: [String: DiscoveredEntrySnapshot] = [:]
    private var selectedEntry: DiscoveredEntrySnapshot?

    init(kind: InventoryKind, dependencies: PageDependencies) {
        self.kind = kind
        self.dependencies = dependencies
        let tableParts = makeAccessibleTable(identifier: "\(kind.pageIdentifier).table")
        table = tableParts.0
        scrollView = tableParts.1
        model = AccessibleTableModel(table: table, columns: [
            TableColumnSpec("name", "Name", width: 210),
            TableColumnSpec("kind", "Type", width: 145),
            TableColumnSpec("state", "State", width: 110),
            TableColumnSpec("owner", "Owner", width: 120),
            TableColumnSpec("path", "Known path", width: 330)
        ])
        super.init(nibName: nil, bundle: nil)
        model.onSelectionChanged = { [weak self] rowID in
            self?.selectedEntry = rowID.flatMap { self?.entries[$0] }
            self?.updateSelectedItem()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let description = kind == .startup
            ? "Read-only view of login items and launch agents. Discovery may be incomplete when locations are protected."
            : "Read-only view of discovered system services. Discovery may be incomplete when access is restricted."
        let header = UIComponents.header(title: kind.title, subtitle: description)
        coverageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.setAccessibilityIdentifier("\(kind.pageIdentifier).discovery-state")
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.textColor = .secondaryLabelColor
        revealButton.target = self
        revealButton.action = #selector(revealSelectedPath)
        revealButton.isEnabled = false
        settingsButton.target = self
        settingsButton.action = #selector(openSystemSettings)
        settingsButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.open-settings")

        let actionRow = NSStackView(views: [revealButton, settingsButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        let info = NSStackView(views: [selectionLabel, actionRow])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 8

        let content = NSStackView(views: [header, coverageLabel, scrollView, info])
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            info.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func update(snapshot: MonitoringSnapshot) {
        let previousID = selectedEntry?.id
        let values = kind == .startup ? snapshot.startupItems : snapshot.services
        entries.removeAll(keepingCapacity: true)
        let rows = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { entry -> AccessibleTableRow in
            let rowID = "\(kind.pageIdentifier).item.\(slug(entry.id))"
            entries[rowID] = entry
            return AccessibleTableRow(id: rowID, values: [
                entry.name,
                entry.kind.rawValue,
                entry.state.rawValue.capitalized,
                UIFormat.ownerName(entry.ownerUID),
                entry.path ?? "Path unavailable"
            ])
        }
        model.replaceRows(rows, in: table)
        if let previousID,
           let rowIndex = model.rows.firstIndex(where: { $0.id == "\(kind.pageIdentifier).item.\(slug(previousID))" }) {
            table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
            selectedEntry = nil
        }
        updateSelectedItem()

        let coverage = coverage(snapshot)
        if let coverage {
            coverageLabel.stringValue = coverage.complete
                ? "Discovery complete · \(values.count) entries found"
                : (coverage.reasons.isEmpty ? "Discovery incomplete · some locations could not be inspected."
                                             : "Discovery incomplete · " + coverage.reasons.joined(separator: " "))
        } else {
            coverageLabel.stringValue = "Discovery status unavailable · completeness is unknown."
        }
        if values.isEmpty && coverage?.complete == false {
            selectionLabel.stringValue = "No entries were returned; discovery is incomplete."
        }
    }

    private func updateSelectedItem() {
        guard let selectedEntry else {
            revealButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.reveal-path")
            revealButton.isEnabled = false
            if !entries.isEmpty {
                selectionLabel.stringValue = "Select an item to inspect its path."
            }
            return
        }
        revealButton.setAccessibilityIdentifier("\(kind.pageIdentifier).action.reveal-path.\(slug(selectedEntry.id))")
        revealButton.isEnabled = selectedEntry.path != nil
        selectionLabel.stringValue = selectedEntry.path ?? "No executable path was reported for this item."
    }

    private func coverage(_ snapshot: MonitoringSnapshot) -> DiscoveryCoverage? {
        if let exact = snapshot.discoveryCoverage[kind.coverageKey] { return exact }
        let token = kind == .startup ? "startup" : "service"
        return snapshot.discoveryCoverage.first(where: { $0.key.lowercased().contains(token) })?.value
    }

    @objc private func revealSelectedPath() {
        guard let path = selectedEntry?.path else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    @objc private func openSystemSettings() {
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "System Settings could not be opened"
            alert.informativeText = "Open System Settings from the Apple menu to inspect startup and service controls."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func slug(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }
}
