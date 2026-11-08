import AppKit
import Foundation
import ServiceManagement
import Sparkle

@MainActor
final class NativeSystemIntegrationAPI: NSObject, SystemIntegrationAPI, SPUUpdaterDelegate {
    private let daemon = SMAppService.daemon(plistName: "run.rosie.microgravity.helper.plist")
    private var updaterController: SPUStandardUpdaterController?
    var onStatusChange: (@MainActor () -> Void)?
    private var updateState: UpdateAvailability { didSet { onStatusChange?() } }
    private let updaterConfigured: Bool
    private var helperConnectionStatus: IntegrationAvailability = .unavailable("Checking helper status.")
    private var statusRefresh: Task<Void, Never>?
    var status: SystemIntegrationStatus {
        SystemIntegrationStatus(helper: helperStatus, loginItem: loginStatus, updates: updateState,
                                helperRegistered: Self.isRegistered(daemon.status))
    }

    override init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = Data(base64Encoded: key)?.count == 32
        updaterConfigured = valid
        updateState = valid ? .idle : .unavailable("A valid Sparkle public key is not configured.")
        super.init()
        if valid {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        // The helper and login item can change in System Settings while the app is
        // in the background, so status is refreshed on activation, not only when
        // Settings is visible. This object lives for the app's lifetime and the
        // observer captures self weakly, so the token is not kept.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshStatus() }
        }
    }

    private var helperStatus: IntegrationAvailability { helperConnectionStatus }

    private var loginStatus: LoginItemAvailability { Self.loginItemAvailability(SMAppService.mainApp.status) }

    /// The helper's launchd plist and executable inside this app bundle.
    nonisolated static let bundledHelperPaths = ["Contents/Library/LaunchDaemons/run.rosie.microgravity.helper.plist",
                                                 "Contents/Helpers/MicrogravityHelper"]

    nonisolated static func helperIsBundled(in bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundledHelperPaths.allSatisfy { FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent($0).path) }
    }

    /// SMAppService reports `.notFound`, not `.notRegistered`, for a service that has never been registered.
    /// Only `.enabled` and `.requiresApproval` mean macOS holds a registration that Remove Helper can undo.
    nonisolated static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// `.notFound` is treated as "not set up yet" so the first registration can be attempted;
    /// a real failure then surfaces as the register() error.
    nonisolated static func loginItemAvailability(_ status: SMAppService.Status) -> LoginItemAvailability {
        switch status {
        case .enabled: return .enabled
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unavailable("Unknown login item status.")
        }
    }

    /// Concurrent callers (the activation observer and an open Settings page) share one pass.
    func refreshStatus() async {
        if let statusRefresh {
            await statusRefresh.value
            return
        }
        await runStatusRefresh()
    }

    private func runStatusRefresh() async {
        let refresh = Task { await performStatusRefresh() }
        statusRefresh = refresh
        await refresh.value
        if statusRefresh == refresh { statusRefresh = nil }
    }

    /// A pass that was already running may have started before a helper change, so
    /// wait for it and then run a fresh one.
    private func refreshStatusAfterChange() async {
        if let statusRefresh { await statusRefresh.value }
        await runStatusRefresh()
    }

    private func helperSigningRequirement() async -> String? {
        await Task.detached(priority: .utility) {
            SigningIdentity.requirement(for: helperSigningIdentifier)
        }.value
    }

    private func performStatusRefresh() async {
        guard let requirement = await helperSigningRequirement() else {
            helperConnectionStatus = .unavailable("A signed app is required for the helper.")
            onStatusChange?()
            return
        }
        switch daemon.status {
        case .notRegistered: helperConnectionStatus = .notConfigured
        case .requiresApproval: helperConnectionStatus = .requiresApproval
        case .notFound:
            // Never registered, unless the bundle really lacks the helper.
            helperConnectionStatus = Self.helperIsBundled() ? .notConfigured : .unavailable("The bundled helper is missing.")
        case .enabled:
            helperConnectionStatus = await HelperHandshake.check(requirement: requirement)
        @unknown default: helperConnectionStatus = .unavailable("Unknown helper status.")
        }
        onStatusChange?()
    }
    func configureHelper() async -> IntegrationActionResult {
        guard await helperSigningRequirement() != nil else {
            return .unavailable("A signed app is required for the helper.")
        }
        do { try daemon.register(); await refreshStatusAfterChange(); return .completed }
        catch { await refreshStatusAfterChange(); return .failed(error.localizedDescription) }
    }
    func removeHelper() async -> IntegrationActionResult {
        do { try await daemon.unregister(); await refreshStatusAfterChange(); return .completed }
        catch { await refreshStatusAfterChange(); return .failed(error.localizedDescription) }
    }
    func setLaunchAtLogin(_ enabled: Bool) async -> IntegrationActionResult {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            onStatusChange?()
            return .completed
        } catch { onStatusChange?(); return .failed(error.localizedDescription) }
    }
    func openLoginItemSettings() async -> IntegrationActionResult {
        SMAppService.openSystemSettingsLoginItems()
        return .completed
    }
    func checkForUpdates() async -> IntegrationActionResult {
        guard updaterConfigured, let updater = updaterController?.updater else {
            return .unavailable("A valid Sparkle public key is not configured.")
        }
        guard updater.canCheckForUpdates else { return .unavailable("An update check is already in progress or the updater is unavailable.") }
        updateState = .checking
        updater.checkForUpdates()
        return .completed
    }
    func installAvailableUpdate() async -> IntegrationActionResult {
        // Sparkle's standard user driver owns the installation confirmation and progress UI.
        await checkForUpdates()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateState = .updateAvailable(version: item.displayVersionString)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // A no-update result can also mean an incompatible OS or hardware.
        let nsError = error as NSError
        let reason = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? Int
        if let reason, reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) ||
            reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            updateState = .current
        } else {
            updateState = .unavailable(error.localizedDescription)
        }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateState = .failed(error.localizedDescription)
    }
}
