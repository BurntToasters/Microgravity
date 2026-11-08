import CryptoKit
import Darwin
import Foundation
import Security

// The wire request carries only the identity the helper must verify. Ownership
// and protection are always looked up locally by the helper.
struct HelperTargetIdentity: Codable, Equatable {
    let pid: Int32
    let seconds: Int64
    let microseconds: Int32
}

struct HelperTerminationPayload: Codable {
    let version: Int
    let target: HelperTargetIdentity
    let force: Bool
}

// Only an already-authorized admin right is accepted; this process never prompts.
enum TerminationService {
    enum TargetAuthorization: Equatable {
        case allowed(HelperTarget)
        case targetRejected
        case authorizationDenied
    }

    private static let consumedAuthorizations = ConsumedAuthorizationStore()
    private static let authorizationLifetime: TimeInterval = 10 * 60
    private static let maximumConsumedAuthorizations = 256

    static func perform(_ data: Data, authorization: Data, clientPID: Int32) -> String {
        guard data.count <= 4096, authorization.count == MemoryLayout<AuthorizationExternalForm>.size,
              let request = try? JSONDecoder().decode(HelperTerminationPayload.self, from: data),
              request.version == helperProtocolVersion else { return "invalidRequest" }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { authorization.copyBytes(to: $0) }
        var authorizationRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &authorizationRef) == errAuthorizationSuccess,
              let authorizationRef else { return "authorizationDenied" }
        defer { AuthorizationFree(authorizationRef, []) }
        let authorized: Bool = "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorizationRef, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
        guard authorized else { return "authorizationDenied" }
        switch authorizeTarget(request.target, authorization: authorization, clientPID: clientPID) {
        case .targetRejected: return "targetRejected"
        case .authorizationDenied: return "authorizationDenied"
        case .allowed(let final):
            return deliverSignal(to: final.pid, force: request.force)
        }
    }

    /// Sends exactly one signal to the already-authorized PID. Signals are never sent
    /// to a process group or to children, so SIGKILL on a parent leaves its children
    /// running, as the UI states.
    static func deliverSignal(to pid: Int32, force: Bool,
                              send: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> String {
        send(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 ? "signalSent" : "signalFailed"
    }

    /// Validates the target twice and only then consumes the authorization form.
    /// A rejected target leaves the form unused; a consumed form is single-use.
    static func authorizeTarget(_ requested: HelperTargetIdentity, authorization: Data, clientPID: Int32,
                                observed: ((Int32) -> HelperTarget?)? = nil) -> TargetAuthorization {
        let resolve: (Int32) -> HelperTarget? = observed ?? { HelperTerminationPolicy.lookupTarget(pid: $0) }
        guard let initial = resolve(requested.pid),
              permits(initial, requested: requested, clientPID: clientPID),
              let final = resolve(requested.pid), final == initial,
              permits(final, requested: requested, clientPID: clientPID) else { return .targetRejected }
        guard consumeAuthorizationForm(authorization) else { return .authorizationDenied }
        return .allowed(final)
    }

    /// Atomically records a validated external form so it can authorize at most
    /// one termination. Expired entries and the size bound are enforced on insert.
    static func consumeAuthorizationForm(_ authorization: Data, now: Date = Date()) -> Bool {
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        let digest = Data(SHA256.hash(data: authorization))
        return consumedAuthorizations.consume(digest, now: now,
                                              lifetime: authorizationLifetime,
                                              maximumCount: maximumConsumedAuthorizations)
    }

    private static func permits(_ observed: HelperTarget, requested: HelperTargetIdentity, clientPID: Int32) -> Bool {
        // The policy compares identity fields only; use observed values for the
        // fields the client no longer supplies.
        let identity = HelperTarget(pid: requested.pid, seconds: requested.seconds, microseconds: requested.microseconds,
                                    owner: observed.owner, protected: observed.protected)
        return HelperTerminationPolicy.permits(observed, requested: identity, clientPID: clientPID, helperPID: getpid())
    }

}

/// Stores consumed authorization digests. Pruning and insertion occur under one
/// lock, preserving atomic single-use checks across helper requests.
private final class ConsumedAuthorizationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Data: Date] = [:]

    func consume(_ digest: Data, now: Date, lifetime: TimeInterval, maximumCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        dates = dates.filter { now.timeIntervalSince($0.value) < lifetime }
        guard dates[digest] == nil, dates.count < maximumCount else { return false }
        dates[digest] = now
        return true
    }
}
