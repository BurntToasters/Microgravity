import AppKit

/// Name column cell: 16 pt application or executable icon, then the name. The outline view supplies
/// the indentation, so group and child names line up with their disclosure triangles.
@MainActor
final class ProcessNameCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("process.cell.name")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")
    private var iconLeading: NSLayoutConstraint?
    private var iconWidth: NSLayoutConstraint?
    private var nameLeading: NSLayoutConstraint?
    private var badgeTrailing: NSLayoutConstraint?
    private var nameTrailingToBadge: NSLayoutConstraint?
    private var nameTrailingToCell: NSLayoutConstraint?
    private var showingCountBadge = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Bundle-style names (com.apple.Virtualization.VirtualMachine) are told apart by their end,
        // so long names lose their middle, not their tail. The full name is in the tooltip.
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        countBadge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        countBadge.textColor = .secondaryLabelColor
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 5
        countBadge.isBezeled = false
        countBadge.drawsBackground = false
        countBadge.setContentHuggingPriority(.required, for: .horizontal)
        countBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.setAccessibilityElement(false)

        addSubview(iconView)
        addSubview(nameField)
        addSubview(countBadge)
        imageView = iconView
        textField = nameField

        let iconLead = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        let iconW = iconView.widthAnchor.constraint(equalToConstant: AppIconProvider.pointSize)
        let nameLead = nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6)
        let badgeTrail = countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        let nameToBadge = nameField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -6)
        let nameToCell = nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)

        iconLeading = iconLead
        iconWidth = iconW
        nameLeading = nameLead
        badgeTrailing = badgeTrail
        nameTrailingToBadge = nameToBadge
        nameTrailingToCell = nameToCell

        NSLayoutConstraint.activate([
            iconLead,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconW,
            iconView.heightAnchor.constraint(equalToConstant: AppIconProvider.pointSize),
            nameLead,
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            nameToCell
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ content: ProcessNameContent) {
        if content.isSectionHeader {
            nameField.stringValue = content.memberCount > 0
                ? "\(content.title) (\(content.memberCount))"
                : content.title
            nameField.font = .systemFont(ofSize: 11.5, weight: .semibold)
            nameField.textColor = .secondaryLabelColor
            iconView.isHidden = true
            iconWidth?.constant = 0
            nameLeading?.constant = 0
            countBadge.isHidden = true
            badgeTrailing?.isActive = false
            nameTrailingToBadge?.isActive = false
            nameTrailingToCell?.isActive = true
        } else {
            nameField.stringValue = content.title
            nameField.font = .systemFont(ofSize: 12, weight: content.isGroup ? .semibold : .regular)
            nameField.textColor = .labelColor
            iconView.isHidden = false
            iconWidth?.constant = AppIconProvider.pointSize
            nameLeading?.constant = 6
            iconView.image = AppIconProvider.icon(forBundlePath: content.bundlePath)

            let showBadge = content.memberCount > 1
            showingCountBadge = showBadge
            countBadge.isHidden = !showBadge
            if showBadge {
                countBadge.stringValue = " \(content.memberCount) "
                applyBadgeAppearance()
                nameTrailingToCell?.isActive = false
                badgeTrailing?.isActive = true
                nameTrailingToBadge?.isActive = true
            } else {
                nameTrailingToBadge?.isActive = false
                badgeTrailing?.isActive = false
                nameTrailingToCell?.isActive = true
            }
        }
        if content.isSectionHeader {
            showingCountBadge = false
        }
        nameField.setAccessibilityIdentifier(content.accessibilityID + ".name")
        nameField.setAccessibilityLabel(content.title)
        toolTip = content.memberCount > 1 && !content.isSectionHeader
            ? String(localized: "\(content.title) (\(content.memberCount) processes)")
            : content.title
        setAccessibilityIdentifier(content.accessibilityID + ".cell.name")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBadgeAppearance()
    }

    private func applyBadgeAppearance() {
        guard showingCountBadge else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            countBadge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.28).cgColor
        }
    }
}

/// Plain text cell for PID and User. Numbers are right-aligned with monospaced digits.
@MainActor
final class ProcessTextCellView: NSTableCellView {
    private let valueField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1
        valueField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueField)
        textField = valueField
        NSLayoutConstraint.activate([
            valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, alignment: NSTextAlignment, monospacedDigits: Bool,
                   valueIdentifier: String, cellIdentifier: String) {
        valueField.stringValue = text
        valueField.alignment = alignment
        valueField.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        valueField.setAccessibilityIdentifier(valueIdentifier)
        valueField.setAccessibilityLabel(text)
        setAccessibilityIdentifier(cellIdentifier)
    }
}

/// Outline row view. Group rows carry a transparent disclosure target over the leading gutter, which
/// the outline view leaves empty. It carries the `process.group.toggle.<slug>` identifier and toggles
/// the group through the controller. Process rows hide it.
@MainActor
final class ProcessRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("process.row.view")

    /// Width of the click target. It stays inside the disclosure gutter, left of the 16 pt icon.
    static let disclosureWidth: CGFloat = 18

    let disclosureTarget = NSButton(title: "", target: nil, action: nil)
    /// Item shown in this row. Set by the controller each time the row view is handed out.
    weak var item: ProcessRowItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        disclosureTarget.isBordered = false
        disclosureTarget.bezelStyle = .regularSquare
        disclosureTarget.setButtonType(.momentaryChange)
        disclosureTarget.title = ""
        disclosureTarget.image = nil
        disclosureTarget.focusRingType = .none
        disclosureTarget.isHidden = true
        disclosureTarget.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureTarget)
        NSLayoutConstraint.activate([
            disclosureTarget.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosureTarget.topAnchor.constraint(equalTo: topAnchor),
            disclosureTarget.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosureTarget.widthAnchor.constraint(equalToConstant: Self.disclosureWidth)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Shows the group's disclosure target with its identifier and state, or hides it for process rows.
    func configureDisclosure(toggleID: String?, expanded: Bool, target: AnyObject, action: Selector) {
        disclosureTarget.isHidden = toggleID == nil
        disclosureTarget.target = target
        disclosureTarget.action = action
        disclosureTarget.identifier = toggleID.map { NSUserInterfaceItemIdentifier($0) }
        disclosureTarget.setAccessibilityIdentifier(toggleID)
        setDisclosureExpanded(expanded)
    }

    func setDisclosureExpanded(_ expanded: Bool) {
        disclosureTarget.setAccessibilityLabel(expanded ? String(localized: "Collapse group") : String(localized: "Expand group"))
        disclosureTarget.toolTip = expanded ? String(localized: "Collapse process group") : String(localized: "Expand process group")
    }
}

/// Column header with the same 8 pt side padding as the value cells, so adjacent right- and
/// left-aligned titles (PID, User) do not run together.
final class PaddedTableHeaderCell: NSTableHeaderCell {
    static let horizontalInset: CGFloat = 8

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect).insetBy(dx: Self.horizontalInset, dy: 0)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: Self.horizontalInset, dy: 0), in: controlView)
    }
}
