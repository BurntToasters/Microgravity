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

    private static let authorizationLock = NSLock()
    private static var consumedAuthorizations: [Data: Date] = [:]
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
        let resolve: (Int32) -> HelperTarget? = observed ?? { lookup($0) }
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
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        consumedAuthorizations = consumedAuthorizations.filter {
            now.timeIntervalSince($0.value) < authorizationLifetime
        }
        guard consumedAuthorizations[digest] == nil,
              consumedAuthorizations.count < maximumConsumedAuthorizations else { return false }
        consumedAuthorizations[digest] = now
        return true
    }

    private static func permits(_ observed: HelperTarget, requested: HelperTargetIdentity, clientPID: Int32) -> Bool {
        // The policy compares identity fields only; use observed values for the
        // fields the client no longer supplies.
        let identity = HelperTarget(pid: requested.pid, seconds: requested.seconds, microseconds: requested.microseconds,
                                    owner: observed.owner, protected: observed.protected)
        return HelperTerminationPolicy.permits(observed, requested: identity, clientPID: clientPID, helperPID: getpid())
    }

    private static func lookup(_ pid: Int32) -> HelperTarget? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // An unknown path is protected because system ownership cannot be ruled out.
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        let executable = pathLength > 0 ? String(cString: path) : ""
        let protectedPath = executable.isEmpty || ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { executable.hasPrefix($0) }
        return HelperTarget(pid: pid, seconds: Int64(info.pbi_start_tvsec), microseconds: Int32(info.pbi_start_tvusec), owner: UInt32(info.pbi_uid), protected: protectedPath || (info.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0)
    }
}
