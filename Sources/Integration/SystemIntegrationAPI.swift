import Foundation

public enum IntegrationAvailability: Equatable, Sendable {
    case available
    case notConfigured
    case requiresApproval
    case unavailable(String)
    case failed(String)
}

public enum LoginItemAvailability: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)
    case failed(String)
}

public enum UpdateAvailability: Equatable {
    case idle
    case checking
    case current
    case updateAvailable(version: String)
    case unavailable(String)
    case failed(String)
}

public struct SystemIntegrationStatus: Equatable {
    public let helper: IntegrationAvailability
    public let loginItem: LoginItemAvailability
    public let updates: UpdateAvailability
    /// True when the helper daemon is registered with ServiceManagement, even if its
    /// connection is unavailable. Decides whether a stuck helper can still be removed.
    public let helperRegistered: Bool

    public init(helper: IntegrationAvailability,
                loginItem: LoginItemAvailability,
                updates: UpdateAvailability,
                helperRegistered: Bool = false) {
        self.helper = helper
        self.loginItem = loginItem
        self.updates = updates
        self.helperRegistered = helperRegistered
    }
}

public enum IntegrationActionResult: Equatable {
    case completed
    case unavailable(String)
    case failed(String)
}

/// The Settings UI depends on this boundary instead of assuming that optional
/// privileged helpers, login items, or an updater are installed.
@MainActor
public protocol SystemIntegrationAPI: AnyObject {
    var status: SystemIntegrationStatus { get }
    var onStatusChange: (@MainActor () -> Void)? { get set }

    func refreshStatus() async
    func removeHelper() async -> IntegrationActionResult
    func configureHelper() async -> IntegrationActionResult
    func setLaunchAtLogin(_ enabled: Bool) async -> IntegrationActionResult
    func openLoginItemSettings() async -> IntegrationActionResult
    func checkForUpdates() async -> IntegrationActionResult
    func installAvailableUpdate() async -> IntegrationActionResult
}

public extension SystemIntegrationAPI {
    var onStatusChange: (@MainActor () -> Void)? {
        get { nil }
        set { }
    }
    func removeHelper() async -> IntegrationActionResult {
        .unavailable("Helper removal is not integrated.")
    }
    func openLoginItemSettings() async -> IntegrationActionResult {
        .unavailable("Opening Login Items settings is not integrated.")
    }
}

/// Honest default until a platform integration supplies these operations.
@MainActor
public final class UnavailableSystemIntegrationAPI: SystemIntegrationAPI {
    public private(set) var status = SystemIntegrationStatus(
        helper: .unavailable("Helper setup is not integrated."),
        loginItem: .unavailable("Login item control is not integrated."),
        updates: .unavailable("Update checks are not integrated."),
        helperRegistered: false
    )

    public init() {}

    public func refreshStatus() async {}

    public func configureHelper() async -> IntegrationActionResult {
        .unavailable("Helper setup is not integrated.")
    }

    public func setLaunchAtLogin(_ enabled: Bool) async -> IntegrationActionResult {
        .unavailable("Login item control is not integrated.")
    }

    public func checkForUpdates() async -> IntegrationActionResult {
        .unavailable("Update checks are not integrated.")
    }

    public func installAvailableUpdate() async -> IntegrationActionResult {
        .unavailable("Update installation is not integrated.")
    }
}
