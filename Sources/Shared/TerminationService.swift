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

// The helper validates the target, writes the approval text from its own lookup, and
// requests this right itself with UI allowed. The approval therefore covers the process
// the helper names and signals, and app-supplied text cannot change what the user sees.
// The rule disallows root, so the helper's own root identity never satisfies it.
enum TerminationService {
    static let terminationRightName = "run.rosie.microgravity.terminate"

    enum TargetAuthorization: Equatable {
        case allowed(HelperTarget)
        case targetRejected
        case authorizationDenied
    }

    enum AuthorizationOutcome: Equatable {
        case granted
        case denied
        case unavailable
    }

    private static let consumedAuthorizations = ConsumedAuthorizationStore()
    private static let rightRegistration = RightRegistrationStore()
    private static let authorizationLifetime: TimeInterval = 10 * 60
    private static let maximumConsumedAuthorizations = 256
    /// The app stops waiting after 120 s. An approval later than this is not acted on,
    /// so the helper never signals a process the app has already reported as not quit.
    static let approvalDeadline: TimeInterval = 100

    /// `lookup`, `authorize`, `send`, `clientConnected` and `now` default to the live
    /// implementations; tests inject them so no dialog is shown and the authorization
    /// database is not touched.
    static func perform(_ data: Data, authorization: Data, clientPID: Int32,
                        lookup: @escaping (Int32) -> HelperTarget? = { HelperTerminationPolicy.lookupTarget(pid: $0) },
                        authorize: (AuthorizationRef, String) -> AuthorizationOutcome = TerminationService.requestTerminationRight,
                        send: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) },
                        clientConnected: () -> Bool = { true },
                        now: () -> Date = { Date() }) -> String {
        let started = now()
        guard data.count <= 4096, authorization.count == MemoryLayout<AuthorizationExternalForm>.size,
              let request = try? JSONDecoder().decode(HelperTerminationPayload.self, from: data),
              request.version == helperProtocolVersion else { return "invalidRequest" }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { authorization.copyBytes(to: $0) }
        var authorizationRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &authorizationRef) == errAuthorizationSuccess,
              let authorizationRef else { return "authorizationDenied" }
        defer { AuthorizationFree(authorizationRef, []) }
        // Validation and single-use consumption come before any prompt, so a rejected
        // target never shows a dialog and never spends the form.
        let validated: HelperTarget
        switch authorizeTarget(request.target, authorization: authorization, clientPID: clientPID, observed: lookup) {
        case .targetRejected: return "targetRejected"
        case .authorizationDenied: return "authorizationDenied"
        case .allowed(let target): validated = target
        }
        let prompt = terminationPrompt(pid: validated.pid, name: processName(pid: validated.pid))
        switch authorize(authorizationRef, prompt) {
        case .unavailable: return "authorizationUnavailable"
        case .denied: return "authorizationDenied"
        case .granted: break
        }
        // A late approval, or one after the client went away, sends nothing: the app has
        // already reported failure and the user may have moved on.
        guard now().timeIntervalSince(started) <= approvalDeadline, clientConnected() else { return "approvalExpired" }
        // The dialog blocks until the user answers, so the process may have exited or its
        // PID may have been reused. Signal only the identical target that is still permitted.
        guard let current = lookup(validated.pid), current == validated,
              permits(current, requested: request.target, clientPID: clientPID) else { return "targetRejected" }
        return deliverSignal(to: current.pid, force: request.force, send: send)
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

    /// Live path only: registers the right if needed, then asks authd with UI allowed.
    /// This blocks until the user answers the dialog.
    static func requestTerminationRight(_ reference: AuthorizationRef, prompt: String) -> AuthorizationOutcome {
        guard registerTerminationRightIfNeeded() else { return .unavailable }
        let status = copyTerminationRight(reference, flags: [.interactionAllowed, .extendRights], prompt: prompt)
        return status == errAuthorizationSuccess ? .granted : .denied
    }

    /// Checks the terminate right on `reference` with the given flags. Without
    /// `.interactionAllowed` authd cannot show UI, so this is safe to call from tests.
    static func copyTerminationRight(_ reference: AuthorizationRef, flags: AuthorizationFlags, prompt: String) -> OSStatus {
        var promptBytes = Array(prompt.utf8)
        return promptBytes.withUnsafeMutableBytes { promptBuffer in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                var environmentItem = AuthorizationItem(name: promptKey, valueLength: promptBuffer.count,
                                                        value: promptBuffer.baseAddress, flags: 0)
                return withUnsafeMutablePointer(to: &environmentItem) { environmentItems in
                    var environment = AuthorizationEnvironment(count: 1, items: environmentItems)
                    return terminationRightName.withCString { name in
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &item) { items in
                            var rights = AuthorizationRights(count: 1, items: items)
                            return AuthorizationCopyRights(reference, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
    }

    /// The rule the helper registers. allow-root is false: the helper runs as root and must
    /// never satisfy this by being root. shared false and timeout 0 make every request prompt.
    static var terminationRule: [String: Any] { [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        "allow-root": false,
        "shared": false,
        "timeout": 0,
        "session-owner": false,
        "version": 1,
        "comment": "Microgravity needs an administrator to quit a process owned by another user.",
    ] }

    /// True when a stored rule keeps the security-relevant settings of `terminationRule`.
    /// Absent allow-root defaults to false; absent shared or timeout default to weaker values.
    static func ruleMatches(_ rule: [String: Any]) -> Bool {
        rule["class"] as? String == "user" && rule["group"] as? String == "admin"
            && (rule["allow-root"] as? Bool ?? false) == false
            && (rule["authenticate-user"] as? Bool ?? true) == true
            && rule["shared"] as? Bool == false && rule["timeout"] as? Int == 0
    }

    /// Registers the terminate right in the authorization database once, on first use.
    /// An existing rule is kept only if it matches; otherwise it is rewritten.
    /// Success is cached; a failure is retried on the next request.
    private static func registerTerminationRightIfNeeded() -> Bool {
        rightRegistration.register {
            terminationRightName.withCString { name in
                var existing: CFDictionary?
                if AuthorizationRightGet(name, &existing) == errAuthorizationSuccess,
                   let stored = existing as? [String: Any], ruleMatches(stored) { return true }
                var reference: AuthorizationRef?
                guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return false }
                defer { AuthorizationFree(reference, []) }
                return AuthorizationRightSet(reference, name, terminationRule as CFDictionary, nil, nil, nil) == errAuthorizationSuccess
            }
        }
    }

    /// The helper's own view of the process name: the kernel name, then the executable's file name.
    static func processName(pid: Int32) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid_t(pid), &name, UInt32(name.count)) > 0 {
            let value = String(cString: name)
            if !value.isEmpty { return value }
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &path, UInt32(path.count)) > 0 else { return nil }
        let file = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        return file.isEmpty ? nil : file
    }

    /// Approval text. Format and control characters are removed and the name is capped at
    /// 64 characters, so a process name cannot reshape the sentence or hide part of it.
    static func terminationPrompt(pid: Int32, name: String?) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        var label = ""
        label.unicodeScalars.append(contentsOf: (name ?? "").unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) })
        label = String(label.prefix(64))
        if label.trimmingCharacters(in: .whitespaces).isEmpty { label = "unknown process" }
        return "Microgravity needs an administrator to quit “\(label)” (PID \(pid)), which belongs to another user."
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

    /// True while any consumed form is still inside its lifetime. Used by the idle exit check.
    static func hasUnexpiredConsumedAuthorizations(now: Date = Date()) -> Bool {
        consumedAuthorizations.hasUnexpired(now: now, lifetime: authorizationLifetime)
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

    func hasUnexpired(now: Date, lifetime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        dates = dates.filter { now.timeIntervalSince($0.value) < lifetime }
        return !dates.isEmpty
    }
}

/// Runs the right registration at most once successfully, under a lock, so concurrent
/// requests never write the authorization database twice.
private final class RightRegistrationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false

    func register(_ body: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !registered { registered = body() }
        return registered
    }
}
