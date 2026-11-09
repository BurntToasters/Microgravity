import AppKit

private enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// NotificationCenter tokens are Objective-C objects. This wrapper owns one token
/// solely so it can be removed when its actor-isolated controller is deallocated.
private final class NotificationObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Plain flipped container so the form is anchored at the top and the scroll view starts at the header.
@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// System Settings 14 style form: right-aligned labels in column 0, controls in column 1, one card per section.
@MainActor
final class SettingsViewController: NSViewController {
    /// Matches the Performance page's caption: quit is limited to other standard users.
    private static let helperPolicyCaption = String(localized: "Lets you quit processes owned by other standard users. System and root processes stay protected.")

    private let dependencies: PageDependencies
    private let appearancePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let intervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let samplingButton = NSButton(title: String(localized: "Pause Sampling"), target: nil, action: nil)
    private let samplingState = UIComponents.label(String(localized: "Sampling is active"), size: 11, color: .secondaryLabelColor)
    private let resetHistoryButton = NSButton(title: String(localized: "Reset App History…"), target: nil, action: nil)
    private let helperDot = StatusDotView()
    private let helperState = UIComponents.label(String(localized: "Checking helper status"), size: 12)
    private let helperButton = NSButton(title: String(localized: "Set Up Helper…"), target: nil, action: nil)
    private let removeHelperButton = NSButton(title: String(localized: "Remove Helper"), target: nil, action: nil)
    private let openHelperSettingsButton = NSButton(title: String(localized: "Open System Settings…"), target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let loginDot = StatusDotView()
    private let loginItemState = UIComponents.label(String(localized: "Checking login item status"), size: 12)
    private let openLoginSettingsButton = NSButton(title: String(localized: "Open Login Items Settings…"), target: nil, action: nil)
    private let updatesDot = StatusDotView()
    private let updatesState = UIComponents.label(String(localized: "Checking update status"), size: 12)
    private let updateCheckButton = NSButton(title: String(localized: "Check for Updates"), target: nil, action: nil)
    private let updateInstallButton = NSButton(title: String(localized: "Install Update…"), target: nil, action: nil)
    private var appActivationObserver: NotificationObserverToken?
    private let versionLabel = UIComponents.label(SettingsViewController.versionText(infoDictionary: Bundle.main.infoDictionary),
                                                  size: 11, color: .secondaryLabelColor)

    /// "Microgravity 0.2.0 (12)" from the bundle's version keys. Plain "Microgravity" when the short version is missing.
    static func versionText(infoDictionary: [String: Any]?) -> String {
        let short = (infoDictionary?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = (infoDictionary?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !short.isEmpty else { return "Microgravity" }
        guard !build.isEmpty else { return String(localized: "Microgravity \(short)") }
        return String(localized: "Microgravity \(short) (\(build))")
    }

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(samplingStateChanged),
                                               name: .samplingStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(title: String(localized: "Settings"), subtitle: String(localized: "Appearance, sampling, history, and optional integrations."))
        let sections = [makeAppearanceSection(), makeSamplingSection(), makeIntegrationSection()]
        alignFormGrids()
        versionLabel.alignment = .center
        versionLabel.maximumNumberOfLines = 1
        versionLabel.setAccessibilityIdentifier("settings.version")
        let content = NSStackView(views: [header] + sections + [versionLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        // Full width so the centered alignment centers the text under the cards.
        versionLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(content)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let clip = scroll.contentView
        let width = content.widthAnchor.constraint(equalTo: clip.widthAnchor, constant: -2 * PageLayout.horizontalInset)
        width.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: PageLayout.topInset),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -PageLayout.bottomInset),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: PageLayout.horizontalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -PageLayout.horizontalInset),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            width
        ])
        refreshSamplingState()
        synchronizeAppearanceControl()
        synchronizeIntervalControl()
        dependencies.integrations.onStatusChange = { [weak self] in self?.updateIntegrationControls() }
        updateIntegrationControls()
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIntegrationStatus() }
        }
        appActivationObserver = NotificationObserverToken(observer)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        synchronizeAppearanceControl()
        synchronizeIntervalControl()
        refreshSamplingState()
        refreshIntegrationStatus()
    }

    // MARK: - Sections

    private func makeAppearanceSection() -> NSView {
        configurePopUp(appearancePopUp,
                       items: AppearanceMode.allCases.map { (title: $0.title, identifier: "settings.appearance.\($0.rawValue)") },
                       action: #selector(chooseAppearance(_:)),
                       identifier: "settings.appearance",
                       label: String(localized: "Appearance"))
        let grid = makeFormGrid()
        grid.addRow(with: [formLabel(String(localized: "Appearance:")), appearancePopUp])
        return UIComponents.card(title: String(localized: "Appearance"), subtitle: String(localized: "Follow macOS or choose a fixed appearance."),
                                 content: grid)
    }

    private func makeSamplingSection() -> NSView {
        configurePopUp(intervalPopUp,
                       items: MonitoringInterval.allCases.map { (title: SamplingControls.longTitle($0), identifier: "settings.refresh.\(Self.intervalIdentifier($0))") },
                       action: #selector(chooseRefreshInterval(_:)),
                       identifier: "settings.refresh",
                       label: String(localized: "Refresh interval"))

        samplingButton.target = self
        samplingButton.action = #selector(toggleSampling)
        samplingButton.setAccessibilityIdentifier("settings.sampling.pause")
        samplingState.setAccessibilityIdentifier("settings.sampling.state")
        let samplingRow = controlStatusRow(samplingButton, samplingState)

        resetHistoryButton.target = self
        resetHistoryButton.action = #selector(confirmHistoryReset)
        resetHistoryButton.setAccessibilityIdentifier("settings.history.reset")

        let grid = makeFormGrid()
        grid.addRow(with: [formLabel(String(localized: "Refresh interval:")), intervalPopUp])
        grid.addRow(with: [formLabel(String(localized: "Sampling:")), samplingRow])
        let historyRow = grid.addRow(with: [formLabel(String(localized: "History:")), resetHistoryButton])
        historyRow.topPadding = 12
        grid.addRow(with: [NSGridCell.emptyContentView, caption(String(localized: "History is kept for 30 days."))])
        return UIComponents.card(title: String(localized: "Sampling and history"),
                                 subtitle: String(localized: "Refresh cadence, pausing, and stored app history."),
                                 content: grid)
    }

    private func makeIntegrationSection() -> NSView {
        helperButton.target = self
        helperButton.action = #selector(configureHelper)
        helperButton.setAccessibilityIdentifier("settings.helper.configure")
        helperButton.isEnabled = false
        removeHelperButton.target = self
        removeHelperButton.action = #selector(removeHelper)
        removeHelperButton.setAccessibilityIdentifier("settings.helper.remove")
        helperState.setAccessibilityIdentifier("settings.helper.state")
        styleAsLinkButton(openHelperSettingsButton, identifier: "settings.helper.open-settings")
        openHelperSettingsButton.action = #selector(openLoginItemSettings)

        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLoginItem(_:))
        loginSwitch.setAccessibilityIdentifier("settings.login-item.toggle")
        loginSwitch.setAccessibilityLabel(String(localized: "Open at login"))
        loginSwitch.toolTip = String(localized: "Start Microgravity when you log in")
        loginSwitch.isEnabled = false
        loginItemState.setAccessibilityIdentifier("settings.login-item.state")
        styleAsLinkButton(openLoginSettingsButton, identifier: "settings.login-item.open-settings")
        openLoginSettingsButton.action = #selector(openLoginItemSettings)

        updateCheckButton.target = self
        updateCheckButton.action = #selector(checkForUpdates)
        updateCheckButton.setAccessibilityIdentifier("settings.updates.check")
        updateCheckButton.isEnabled = false
        updateInstallButton.target = self
        updateInstallButton.action = #selector(installUpdate)
        updateInstallButton.setAccessibilityIdentifier("settings.updates.install")
        updateInstallButton.isEnabled = false
        updatesState.setAccessibilityIdentifier("settings.updates.state")

        let grid = makeFormGrid()
        grid.addRow(with: [formLabel(String(localized: "Privileged helper:")), statusRow(helperDot, helperState, extra: openHelperSettingsButton)])
        grid.addRow(with: [NSGridCell.emptyContentView, caption(Self.helperPolicyCaption)])
        grid.addRow(with: [NSGridCell.emptyContentView, buttonRow([helperButton, removeHelperButton])])
        let loginRow = grid.addRow(with: [formLabel(String(localized: "Open at login:")), loginSwitch])
        loginRow.topPadding = 12
        grid.addRow(with: [NSGridCell.emptyContentView, statusRow(loginDot, loginItemState, extra: openLoginSettingsButton)])
        let updatesRow = grid.addRow(with: [formLabel(String(localized: "Software updates:")), statusRow(updatesDot, updatesState)])
        updatesRow.topPadding = 12
        grid.addRow(with: [NSGridCell.emptyContentView, buttonRow([updateCheckButton, updateInstallButton])])
        return UIComponents.card(title: String(localized: "Optional integrations"),
                                 subtitle: String(localized: "Optional features that need your approval in macOS."),
                                 content: grid)
    }

    /// Borderless, link-colored button for a secondary action next to a status line. Hidden until a state needs it.
    private func styleAsLinkButton(_ button: NSButton, identifier: String) {
        button.target = self
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: 12)
        ])
        button.setAccessibilityIdentifier(identifier)
        button.isHidden = true
    }

    // MARK: - Form building

    /// Every card's form grid, so their label columns can share one width.
    private(set) var formGrids: [NSGridView] = []

    /// Gives every card the same label column (the widest label) and stretches each grid to its card,
    /// so labels line up across cards and do not move when a value changes.
    private func alignFormGrids() {
        let labelWidth = formGrids.flatMap { grid in
            (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width }
        }.max() ?? 0
        for grid in formGrids {
            grid.column(at: 0).width = ceil(labelWidth)
            if let rows = grid.superview {
                grid.trailingAnchor.constraint(equalTo: rows.trailingAnchor).isActive = true
            }
        }
    }

    private func makeFormGrid() -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        formGrids.append(grid)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = UIComponents.label(text, size: 12)
        label.alignment = .right
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let field = UIComponents.label(text, size: 11, color: .secondaryLabelColor)
        // The shared label truncates, and truncation forces a single line. Captions wrap instead.
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 480
        // Wrapping must not widen the form: the grid may compress the caption to its column.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Dot, status text, and an optional trailing control on one line. The text truncates before the row grows.
    private func statusRow(_ dot: StatusDotView, _ text: NSTextField, extra: NSView? = nil) -> NSStackView {
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [dot, text]
        if let extra { views.append(extra) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    /// A control and its status caption on one line, for example the Pause button and "Sampling every 1 second.".
    private func controlStatusRow(_ control: NSView, _ text: NSTextField) -> NSStackView {
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [control, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func configurePopUp(_ popUp: NSPopUpButton, items: [(title: String, identifier: String)],
                                action: Selector, identifier: String, label: String) {
        popUp.removeAllItems()
        for entry in items {
            popUp.addItem(withTitle: entry.title)
            if let item = popUp.lastItem {
                item.identifier = NSUserInterfaceItemIdentifier(entry.identifier)
                item.setAccessibilityIdentifier(entry.identifier)
            }
        }
        popUp.target = self
        popUp.action = action
        popUp.setAccessibilityIdentifier(identifier)
        popUp.setAccessibilityLabel(label)
    }

    private static func intervalIdentifier(_ interval: MonitoringInterval) -> String {
        interval == .halfSecond ? "0.5" : String(Int(interval.rawValue))
    }

    // MARK: - Actions

    @objc private func chooseAppearance(_ sender: NSPopUpButton) {
        let modes = AppearanceMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        AppearancePreference.apply(modes[sender.indexOfSelectedItem].rawValue)
        synchronizeAppearanceControl()
    }

    @objc private func chooseRefreshInterval(_ sender: NSPopUpButton) {
        let intervals = MonitoringInterval.allCases
        guard intervals.indices.contains(sender.indexOfSelectedItem) else { return }
        // The notification refreshes this page's controls too, along with Performance and the sidebar footer.
        SamplingControls.setInterval(intervals[sender.indexOfSelectedItem], store: dependencies.monitoringStore)
    }

    @objc private func toggleSampling() {
        SamplingControls.togglePause(store: dependencies.monitoringStore)
    }

    /// Keeps the interval pop-up and pause button current when Performance or the sidebar changes sampling.
    @objc private func samplingStateChanged() {
        synchronizeIntervalControl()
        refreshSamplingState()
    }

    @objc private func confirmHistoryReset() {
        Task { [weak self] in
            guard let self else { return }
            let response = await SheetAlert.present(
                on: view.window,
                style: .warning,
                messageText: String(localized: "Reset App History"),
                informativeText: String(localized: "This clears Microgravity’s stored 30-day aggregate history. It does not change process or operating-system state."),
                buttons: [String(localized: "Reset History"), String(localized: "Cancel")],
                defaultButtonIdentifier: "settings.history.reset.confirm",
                destructiveButtonIndex: 0
            )
            guard response == .alertFirstButtonReturn else { return }
            do {
                try await dependencies.monitoringStore.resetHistory()
            } catch {
                await showIntegrationError(String(localized: "History could not be reset"), message: error.localizedDescription)
            }
        }
    }

    @objc private func configureHelper() {
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.configureHelper() }
    }

    @objc private func removeHelper() {
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.removeHelper() }
    }

    /// The switch reflects the login-item state. While approval is pending it stays off and acts as a link to Login Items.
    @objc private func toggleLoginItem(_ sender: NSSwitch) {
        let integrations = dependencies.integrations
        switch dependencies.integrations.status.loginItem {
        case .requiresApproval:
            sender.state = .off
            runIntegrationAction { await integrations.openLoginItemSettings() }
        case .unavailable:
            sender.state = .off
        case .enabled, .disabled, .failed:
            let enabled = sender.state == .on
            runIntegrationAction { await integrations.setLaunchAtLogin(enabled) }
        }
    }

    @objc private func openLoginItemSettings() {
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.openLoginItemSettings() }
    }

    private func refreshIntegrationStatus() {
        let integrations = dependencies.integrations
        Task { [weak self] in
            await integrations.refreshStatus()
            self?.updateIntegrationControls()
        }
    }

    @objc private func checkForUpdates() {
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.checkForUpdates() }
    }

    @objc private func installUpdate() {
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.installAvailableUpdate() }
    }

    private func runIntegrationAction(_ action: @escaping @MainActor () async -> IntegrationActionResult) {
        Task { [weak self] in
            guard let self else { return }
            let result = await action()
            await dependencies.integrations.refreshStatus()
            updateIntegrationControls()
            switch result {
            case .completed: break
            case .unavailable(let message): await showIntegrationError(String(localized: "Integration unavailable"), message: message)
            case .failed(let message): await showIntegrationError(String(localized: "Integration failed"), message: message)
            }
        }
    }

    // MARK: - State

    private func updateIntegrationControls() {
        let status = dependencies.integrations.status
        helperDot.tone = IntegrationStatusTone.helper(status.helper)
        setStatus(helperState, describe(status.helper))
        // Setup registers the helper again, so it is off while the helper is already available or unavailable.
        switch status.helper {
        case .available, .unavailable:
            helperButton.isEnabled = false
        case .notConfigured, .requiresApproval, .failed:
            helperButton.isEnabled = true
        }
        openHelperSettingsButton.isHidden = status.helper != .requiresApproval
        removeHelperButton.isEnabled = canRemoveHelper(status)

        loginDot.tone = IntegrationStatusTone.loginItem(status.loginItem)
        setStatus(loginItemState, describe(status.loginItem))
        switch status.loginItem {
        case .enabled:
            loginSwitch.state = .on
            loginSwitch.isEnabled = true
        case .disabled, .failed, .requiresApproval:
            loginSwitch.state = .off
            loginSwitch.isEnabled = true
        case .unavailable:
            loginSwitch.state = .off
            loginSwitch.isEnabled = false
        }
        openLoginSettingsButton.isHidden = status.loginItem != .requiresApproval

        updatesDot.tone = IntegrationStatusTone.updates(status.updates)
        setStatus(updatesState, describe(status.updates))
        switch status.updates {
        case .idle, .checking, .current, .failed:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = false
        case .updateAvailable:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = true
        case .unavailable:
            updateCheckButton.isEnabled = false
            updateInstallButton.isEnabled = false
        }
    }

    private func canRemoveHelper(_ status: SystemIntegrationStatus) -> Bool {
        switch status.helper {
        case .available, .requiresApproval, .failed:
            return true
        case .notConfigured:
            return false
        case .unavailable:
            // A registered daemon can be stuck unavailable (for example after a
            // handshake failure) and still needs to remain removable.
            return status.helperRegistered
        }
    }

    /// Sets a status line and mirrors it into the accessibility label and tooltip, so a truncated line stays readable.
    private func setStatus(_ field: NSTextField, _ text: String) {
        field.stringValue = text
        field.setAccessibilityLabel(text)
        field.toolTip = text
    }

    private func describe(_ status: IntegrationAvailability) -> String {
        switch status {
        case .available: return String(localized: "Available")
        case .notConfigured: return String(localized: "Not configured")
        case .requiresApproval: return String(localized: "Requires approval in System Settings")
        case .unavailable(let reason): return String(localized: "Unavailable · \(reason)")
        case .failed(let reason): return String(localized: "Failed · \(reason)")
        }
    }

    private func describe(_ status: LoginItemAvailability) -> String {
        switch status {
        case .enabled: return String(localized: "Enabled")
        case .disabled: return String(localized: "Disabled")
        case .requiresApproval: return String(localized: "Requires approval in System Settings")
        case .unavailable(let reason): return String(localized: "Unavailable · \(reason)")
        case .failed(let reason): return String(localized: "Failed · \(reason)")
        }
    }

    private func describe(_ status: UpdateAvailability) -> String {
        switch status {
        case .idle: return String(localized: "Not checked")
        case .checking: return String(localized: "Checking…")
        case .current: return String(localized: "Up to date")
        case .updateAvailable(let version): return String(localized: "Update available · \(version)")
        case .unavailable(let reason): return String(localized: "Unavailable · \(reason)")
        case .failed(let reason): return String(localized: "Failed · \(reason)")
        }
    }

    private func synchronizeAppearanceControl() {
        let selected = AppearanceMode(rawValue: AppearancePreference.current()) ?? .system
        if let index = AppearanceMode.allCases.firstIndex(of: selected) {
            appearancePopUp.selectItem(at: index)
        }
    }

    private func synchronizeIntervalControl() {
        if let index = MonitoringInterval.allCases.firstIndex(of: dependencies.monitoringStore.interval) {
            intervalPopUp.selectItem(at: index)
        }
    }

    private func refreshSamplingState() {
        let store = dependencies.monitoringStore
        samplingButton.title = store.isPaused ? String(localized: "Resume Sampling") : String(localized: "Pause Sampling")
        setStatus(samplingState, store.isPaused
            ? String(localized: "Paused · the last sample remains visible.")
            : String(localized: "Sampling every \(SamplingControls.longTitle(store.interval))."))
    }

    private func showIntegrationError(_ title: String, message: String) async {
        _ = await SheetAlert.present(on: view.window, style: .warning, messageText: title,
                                     informativeText: message, buttons: [String(localized: "OK")])
    }
}
