import AppKit
import ServiceManagement

private enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let dependencies: PageDependencies
    private var appearanceButtons: [AppearanceMode: NSButton] = [:]
    private var intervalButtons: [MonitoringInterval: NSButton] = [:]
    private let samplingButton = NSButton(title: "Pause Sampling", target: nil, action: nil)
    private let samplingState = NSTextField(labelWithString: "Sampling is active")
    private let helperState = NSTextField(labelWithString: "Checking helper status")
    private let loginItemState = NSTextField(labelWithString: "Checking login item status")
    private let updatesState = NSTextField(labelWithString: "Checking update status")
    private let helperButton = NSButton(title: "Set Up Helper…", target: nil, action: nil)
    private let removeHelperButton = NSButton(title: "Remove Helper", target: nil, action: nil)
    private let loginItemButton = NSButton(title: "Turn On at Login", target: nil, action: nil)
    private let updateCheckButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let updateInstallButton = NSButton(title: "Install Update…", target: nil, action: nil)

    init(dependencies: PageDependencies) {
        self.dependencies = dependencies
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = DynamicWindowBackgroundView()

        let header = UIComponents.header(title: "Settings", subtitle: "Appearance, sampling, history, and optional integrations.")
        let appearanceSection = makeAppearanceSection()
        let samplingSection = makeSamplingSection()
        let integrationSection = makeIntegrationSection()
        let content = NSStackView(views: [header, appearanceSection, samplingSection, integrationSection])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        for section in [appearanceSection, samplingSection, integrationSection] {
            section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            header.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        refreshSamplingState()
        dependencies.integrations.onStatusChange = { [weak self] in self?.updateIntegrationControls() }
        updateIntegrationControls()
        Task { [weak self] in
            guard let self else { return }
            await dependencies.integrations.refreshStatus()
            updateIntegrationControls()
        }
    }

    private func makeAppearanceSection() -> NSView {
        var controls: [NSButton] = []
        for (index, mode) in AppearanceMode.allCases.enumerated() {
            let button = makeRadioButton(title: mode.title,
                                         identifier: "settings.appearance.\(mode.rawValue)",
                                         tag: index,
                                         action: #selector(chooseAppearance(_:)))
            appearanceButtons[mode] = button
            controls.append(button)
        }
        synchronizeAppearanceButtons()
        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.spacing = 16
        return UIComponents.card(title: "Appearance", subtitle: "Follow macOS or choose a fixed appearance.",
                                 content: row)
    }

    private func makeSamplingSection() -> NSView {
        var controls: [NSButton] = []
        for (index, interval) in MonitoringInterval.allCases.enumerated() {
            let identifierValue = interval == .halfSecond ? "0.5" : String(Int(interval.rawValue))
            let title = "\(identifierValue)s"
            let button = makeRadioButton(title: title,
                                         identifier: "settings.refresh.\(identifierValue)",
                                         tag: index,
                                         action: #selector(chooseRefreshInterval(_:)))
            intervalButtons[interval] = button
            controls.append(button)
        }
        synchronizeIntervalButtons()

        samplingButton.target = self
        samplingButton.action = #selector(toggleSampling)
        samplingButton.setAccessibilityIdentifier("settings.sampling.pause")
        let intervalTitle = UIComponents.label("Refresh interval", size: 12, weight: .medium)
        let intervalRow = NSStackView(views: [intervalTitle] + controls)
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY
        intervalRow.spacing = 14

        samplingState.font = .systemFont(ofSize: 11)
        samplingState.textColor = .secondaryLabelColor
        samplingState.setAccessibilityIdentifier("settings.sampling.state")
        let pauseRow = NSStackView(views: [samplingButton, samplingState])
        pauseRow.orientation = .horizontal
        pauseRow.alignment = .centerY
        pauseRow.spacing = 12

        let reset = NSButton(title: "Reset App History…", target: self, action: #selector(confirmHistoryReset))
        reset.setAccessibilityIdentifier("settings.history.reset")
        let content = NSStackView(views: [intervalRow, pauseRow, reset])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        return UIComponents.card(title: "Sampling and history", subtitle: "Adjust refresh cadence or pause collection. History is retained for 30 days.",
                                 content: content)
    }

    private func makeIntegrationSection() -> NSView {
        helperState.font = .systemFont(ofSize: 11)
        helperState.textColor = .secondaryLabelColor
        helperState.setAccessibilityIdentifier("settings.helper.state")
        loginItemState.font = .systemFont(ofSize: 11)
        loginItemState.textColor = .secondaryLabelColor
        loginItemState.setAccessibilityIdentifier("settings.login-item.state")
        updatesState.font = .systemFont(ofSize: 11)
        updatesState.textColor = .secondaryLabelColor
        updatesState.setAccessibilityIdentifier("settings.updates.state")

        helperButton.target = self
        helperButton.action = #selector(configureHelper)
        helperButton.setAccessibilityIdentifier("settings.helper.configure")
        helperButton.isEnabled = false
        removeHelperButton.target = self
        removeHelperButton.action = #selector(removeHelper)
        removeHelperButton.setAccessibilityIdentifier("settings.helper.remove")
        loginItemButton.target = self
        loginItemButton.action = #selector(toggleLoginItem)
        loginItemButton.setAccessibilityIdentifier("settings.login-item.toggle")
        loginItemButton.isEnabled = false
        updateCheckButton.target = self
        updateCheckButton.action = #selector(checkForUpdates)
        updateCheckButton.setAccessibilityIdentifier("settings.updates.check")
        updateCheckButton.isEnabled = false
        updateInstallButton.target = self
        updateInstallButton.action = #selector(installUpdate)
        updateInstallButton.setAccessibilityIdentifier("settings.updates.install")
        updateInstallButton.isEnabled = false

        let helper = makeIntegrationRow(title: "Privileged helper", detail: helperState, button: helperButton, secondaryButton: removeHelperButton)
        let login = makeIntegrationRow(title: "Open at login", detail: loginItemState, button: loginItemButton)
        let updates = makeIntegrationRow(title: "Software updates", detail: updatesState,
                                         button: updateCheckButton, secondaryButton: updateInstallButton)
        let content = NSStackView(views: [helper, login, updates])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        return UIComponents.card(title: "Optional integrations", subtitle: "Control is unavailable until a platform integration is installed.",
                                 content: content)
    }

    private func makeIntegrationRow(title: String, detail: NSTextField, button: NSButton,
                                    secondaryButton: NSButton? = nil) -> NSView {
        let titleField = UIComponents.label(title, size: 12, weight: .medium)
        let buttons = [button] + (secondaryButton.map { [$0] } ?? [])
        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        let text = NSStackView(views: [titleField, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [text, NSView(), buttonStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        return row
    }

    private func makeRadioButton(title: String, identifier: String, tag: Int, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.setButtonType(.radio)
        button.tag = tag
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    @objc private func chooseAppearance(_ sender: NSButton) {
        let modes = AppearanceMode.allCases
        guard modes.indices.contains(sender.tag) else { return }
        AppearancePreference.apply(modes[sender.tag].rawValue)
        synchronizeAppearanceButtons()
    }

    @objc private func chooseRefreshInterval(_ sender: NSButton) {
        let intervals = MonitoringInterval.allCases
        guard intervals.indices.contains(sender.tag) else { return }
        let interval = intervals[sender.tag]
        dependencies.monitoringStore.setInterval(interval)
        UserDefaults.standard.set(interval.rawValue, forKey: "monitoring.refreshInterval")
        synchronizeIntervalButtons()
    }

    @objc private func toggleSampling() {
        if dependencies.monitoringStore.isPaused {
            dependencies.monitoringStore.resume()
        } else {
            dependencies.monitoringStore.pause()
        }
        refreshSamplingState()
    }

    @objc private func confirmHistoryReset() {
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
                showIntegrationError("History could not be reset", message: error.localizedDescription)
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

    @objc private func toggleLoginItem() {
        let enabled: Bool
        switch dependencies.integrations.status.loginItem {
        case .enabled: enabled = false
        default: enabled = true
        }
        let integrations = dependencies.integrations
        runIntegrationAction { await integrations.setLaunchAtLogin(enabled) }
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
            case .unavailable(let message): showIntegrationError("Integration unavailable", message: message)
            case .failed(let message): showIntegrationError("Integration failed", message: message)
            }
        }
    }

    private func updateIntegrationControls() {
        let status = dependencies.integrations.status
        helperState.stringValue = describe(status.helper)
        switch status.helper {
        case .unavailable: helperButton.isEnabled = false
        default: helperButton.isEnabled = true
        }
        removeHelperButton.isEnabled = canRemoveHelper(status.helper)
        loginItemState.stringValue = describe(status.loginItem)
        switch status.loginItem {
        case .enabled:
            loginItemButton.title = "Turn Off at Login"
            loginItemButton.isEnabled = true
        case .disabled:
            loginItemButton.title = "Turn On at Login"
            loginItemButton.isEnabled = true
        case .requiresApproval:
            loginItemButton.title = "Open at Login Settings"
            loginItemButton.isEnabled = true
        case .failed:
            loginItemButton.title = "Retry Open at Login"
            loginItemButton.isEnabled = true
        case .unavailable:
            loginItemButton.title = "Open at Login Settings"
            loginItemButton.isEnabled = false
        }
        updatesState.stringValue = describe(status.updates)
        switch status.updates {
        case .idle, .checking:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = false
        case .current:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = false
        case .updateAvailable:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = true
        case .failed:
            updateCheckButton.isEnabled = true
            updateInstallButton.isEnabled = false
        case .unavailable:
            updateCheckButton.isEnabled = false
            updateInstallButton.isEnabled = false
        }
    }

    private func canRemoveHelper(_ status: IntegrationAvailability) -> Bool {
        switch status {
        case .available, .requiresApproval, .failed:
            return true
        case .notConfigured:
            return false
        case .unavailable:
            // A registered daemon can be stuck unavailable (for example after a
            // handshake failure) and still needs to remain removable.
            return SMAppService.daemon(plistName: helperMachService + ".plist").status != .notRegistered
        }
    }

    private func describe(_ status: IntegrationAvailability) -> String {
        switch status {
        case .available: return "Available"
        case .notConfigured: return "Not configured"
        case .requiresApproval: return "Requires approval in System Settings"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .failed(let reason): return "Unavailable · \(reason)"
        }
    }

    private func describe(_ status: LoginItemAvailability) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .requiresApproval: return "Requires approval in System Settings"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .failed(let reason): return "Unavailable · \(reason)"
        }
    }

    private func describe(_ status: UpdateAvailability) -> String {
        switch status {
        case .idle: return "Not checked"
        case .checking: return "Checking…"
        case .current: return "Up to date"
        case .updateAvailable(let version): return "Update available · \(version)"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .failed(let reason): return "Unavailable · \(reason)"
        }
    }

    private func synchronizeAppearanceButtons() {
        let selected = AppearanceMode(rawValue: AppearancePreference.current()) ?? .system
        for (mode, button) in appearanceButtons { button.state = mode == selected ? .on : .off }
    }

    private func synchronizeIntervalButtons() {
        for (interval, button) in intervalButtons {
            button.state = interval == dependencies.monitoringStore.interval ? .on : .off
        }
    }

    private func refreshSamplingState() {
        let isPaused = dependencies.monitoringStore.isPaused
        samplingButton.title = isPaused ? "Resume Sampling" : "Pause Sampling"
        samplingState.stringValue = isPaused ? "Paused · the last sample remains visible." : "Sampling every \(dependencies.monitoringStore.interval.rawValue) seconds."
    }

    private func showIntegrationError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
