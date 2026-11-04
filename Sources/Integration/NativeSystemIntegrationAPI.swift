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
    var status: SystemIntegrationStatus {
        SystemIntegrationStatus(helper: helperStatus, loginItem: loginStatus, updates: updateState)
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
    }

    private var helperStatus: IntegrationAvailability { helperConnectionStatus }

    private var loginStatus: LoginItemAvailability {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("The app is not installed in a supported location.")
        @unknown default: return .unavailable("Unknown login item status.")
        }
    }

    func refreshStatus() async {
        guard let requirement = SigningIdentity.requirement(for: helperSigningIdentifier) else {
            helperConnectionStatus = .unavailable("A signed app is required for the helper.")
            onStatusChange?()
            return
        }
        switch daemon.status {
        case .notRegistered: helperConnectionStatus = .notConfigured
        case .requiresApproval: helperConnectionStatus = .requiresApproval
        case .notFound: helperConnectionStatus = .unavailable("The bundled helper is missing.")
        case .enabled:
            helperConnectionStatus = await HelperHandshake.check(requirement: requirement)
        @unknown default: helperConnectionStatus = .unavailable("Unknown helper status.")
        }
        onStatusChange?()
    }
    func configureHelper() async -> IntegrationActionResult {
        guard SigningIdentity.requirement(for: helperSigningIdentifier) != nil else {
            return .unavailable("A signed app is required for the helper.")
        }
        do { try daemon.register(); await refreshStatus(); return .completed }
        catch { await refreshStatus(); return .failed(error.localizedDescription) }
    }
    func removeHelper() async -> IntegrationActionResult {
        do { try await daemon.unregister(); await refreshStatus(); return .completed }
        catch { await refreshStatus(); return .failed(error.localizedDescription) }
    }
    func setLaunchAtLogin(_ enabled: Bool) async -> IntegrationActionResult {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            onStatusChange?()
            return .completed
        } catch { onStatusChange?(); return .failed(error.localizedDescription) }
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
