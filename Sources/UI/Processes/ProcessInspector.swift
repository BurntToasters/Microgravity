import AppKit

/// One label and value line in the process inspector.
struct ProcessInspectorRow: Equatable {
    let label: String
    let value: String
    let toolTip: String?
    let isMonospaced: Bool
}

/// Pure row content for the Inspect popover. No AppKit views.
///
/// For a group row the leader's identity (PID, parent, start time) is shown with the group's totals: CPU,
/// memory, rates and network are the group's own values, and "since start" sums the members, so the popover
/// matches the row the user clicked. Unavailable readings keep their reason text and are never shown as 0.
@MainActor
enum ProcessInspectorModel {
    static func rows(process: ProcessSnapshot, group: ProcessGroupSnapshot?, snapshot: MonitoringSnapshot,
                     ownerName: (UInt32?) -> String) -> [ProcessInspectorRow] {
        let timestamp = snapshot.timestamp
        let byIdentity = Dictionary(snapshot.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members: [ProcessSnapshot?] = group.map { $0.members.map { byIdentity[$0] } } ?? [process]

        func aggregate(_ reading: (ProcessSnapshot) -> MetricReading, unit: MetricUnit) -> MetricReading {
            guard group != nil else { return reading(process) }
            let readings = members.map { member in
                member.map(reading) ?? MetricReading(unavailable: unit, timestamp: timestamp, reason: .notCollected)
            }
            return SystemMonitorCollector.combineRates(readings, unit: unit, timestamp: timestamp)
        }

        let cpu = group?.cpuPercent ?? process.cpuPercent
        let memory = group?.memoryBytes ?? process.memoryBytes
        let diskRead = group?.diskReadBytesPerSecond ?? process.diskReadBytesPerSecond
        let diskWrite = group?.diskWriteBytesPerSecond ?? process.diskWriteBytesPerSecond
        let readTotal = aggregate({ $0.diskReadTotalBytes }, unit: .bytes)
        let writeTotal = aggregate({ $0.diskWriteTotalBytes }, unit: .bytes)
        let network = aggregate({ networkReading($0, snapshot: snapshot) }, unit: .bytesPerSecond)

        let started = ProcessesViewController.startTimeFormatter.string(
            from: ProcessesViewController.startDate(process.id.startTime)
        )
        let appPath = group?.executablePath ?? process.executablePath
        let appBundle: String
        if let group, group.association != .applicationBundle {
            appBundle = String(localized: "None")
        } else {
            appBundle = UIText.appBundlePath(forExecutable: appPath) ?? String(localized: "None")
        }

        return [
            ProcessInspectorRow(label: String(localized: "Name"), value: group?.title ?? process.name,
                                toolTip: nil, isMonospaced: false),
            ProcessInspectorRow(label: String(localized: "PID"), value: String(process.id.pid),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Parent"), value: parentText(process, byIdentity: byIdentity),
                                toolTip: nil, isMonospaced: false),
            ProcessInspectorRow(label: String(localized: "Owner"), value: ownerName(process.ownerUID),
                                toolTip: nil, isMonospaced: false),
            ProcessInspectorRow(label: String(localized: "Started"), value: started,
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Executable Path"),
                                value: process.executablePath ?? String(localized: "Unavailable"),
                                toolTip: process.executablePath, isMonospaced: false),
            ProcessInspectorRow(label: String(localized: "App Bundle"), value: appBundle,
                                toolTip: UIText.appBundlePath(forExecutable: appPath), isMonospaced: false),
            ProcessInspectorRow(label: String(localized: "CPU"), value: UIFormat.metric(cpu),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Memory"), value: UIFormat.metric(memory),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Disk Read Rate"), value: UIFormat.metric(diskRead),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Disk Write Rate"), value: UIFormat.metric(diskWrite),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Read Since Start"), value: UIFormat.metric(readTotal),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Written Since Start"), value: UIFormat.metric(writeTotal),
                                toolTip: nil, isMonospaced: true),
            ProcessInspectorRow(label: String(localized: "Network"), value: UIFormat.metric(network),
                                toolTip: nil, isMonospaced: true)
        ]
    }

    /// "<name> (PID n)" when the parent is listed, "PID n" when only its PID is known, otherwise "Unavailable".
    static func parentText(_ process: ProcessSnapshot, byIdentity: [ProcessIdentity: ProcessSnapshot]) -> String {
        if let parentIdentity = process.parentIdentity {
            if let parent = byIdentity[parentIdentity] {
                return String(localized: "\(parent.name) (PID \(parent.id.pid))")
            }
            return String(localized: "PID \(parentIdentity.pid)")
        }
        if let parentPID = process.parentPID {
            return String(localized: "PID \(parentPID)")
        }
        return String(localized: "Unavailable")
    }

    /// The process's network rate, or a reading that explains why it is missing (capability reason, else not collected).
    private static func networkReading(_ process: ProcessSnapshot, snapshot: MonitoringSnapshot) -> MetricReading {
        if let reading = process.advancedMetrics[.processNetwork] { return reading }
        let capability = snapshot.capabilities[.processNetwork]
        let unavailable = capability?.available == false
        return MetricReading(unavailable: .bytesPerSecond, timestamp: snapshot.timestamp,
                             reason: unavailable ? (capability?.reason ?? .notCollected) : .notCollected,
                             detail: unavailable ? capability?.detail : nil)
    }
}

/// Inspect popover content: an icon and title, a grid of label and value rows, and a Copy Path button.
///
/// `update(title:icon:executablePath:rows:)` refreshes the values in place while the popover is open.
/// The grid is rebuilt only when the set of labels changes.
@MainActor
final class ProcessInspectorViewController: NSViewController {
    static let width: CGFloat = 360
    private static let valueWidth: CGFloat = 220

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let copyButton = NSButton(title: String(localized: "Copy Path"), target: nil, action: nil)
    private var renderedLabels: [String] = []
    private var valueFields: [NSTextField] = []
    private var executablePath: String?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        view.setAccessibilityIdentifier("process.inspector")

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        let header = NSStackView(views: [iconView, titleField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyPath(_:))
        copyButton.setAccessibilityIdentifier("process.inspector.copy-path")
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [footerSpacer, copyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill

        let caption = NSTextField(labelWithString: String(localized: "Updates live while open"))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.setAccessibilityIdentifier("process.inspector.footer")

        let stack = NSStackView(views: [header, grid, buttons, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
    }

    /// Refreshes the header and every row. Values change in place; the grid is rebuilt only for new labels.
    func update(title: String, icon: NSImage, executablePath: String?, rows: [ProcessInspectorRow]) {
        loadViewIfNeeded()
        titleField.stringValue = title
        iconView.image = icon
        self.executablePath = executablePath
        copyButton.isEnabled = executablePath != nil

        if rows.map(\.label) == renderedLabels {
            for (field, row) in zip(valueFields, rows) {
                apply(row, to: field)
            }
        } else {
            rebuildGrid(rows)
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    private func rebuildGrid(_ rows: [ProcessInspectorRow]) {
        while grid.numberOfRows > 0 {
            grid.removeRow(at: grid.numberOfRows - 1)
        }
        valueFields = []
        renderedLabels = rows.map(\.label)
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)

            let value = NSTextField(labelWithString: "")
            value.isSelectable = true
            value.maximumNumberOfLines = 1
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            value.widthAnchor.constraint(lessThanOrEqualToConstant: Self.valueWidth).isActive = true
            value.setAccessibilityIdentifier("process.inspector.\(UIText.slug(row.label))")
            apply(row, to: value)
            valueFields.append(value)
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for index in rows.indices {
            grid.row(at: index).rowAlignment = .firstBaseline
        }
    }

    private func apply(_ row: ProcessInspectorRow, to field: NSTextField) {
        field.stringValue = row.value
        field.toolTip = row.toolTip
        field.font = row.isMonospaced
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        field.setAccessibilityLabel("\(row.label), \(row.value)")
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let executablePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(executablePath, forType: .string)
    }
}
