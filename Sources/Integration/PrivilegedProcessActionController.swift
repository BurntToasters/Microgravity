import Darwin
import Foundation
import Security
import ServiceManagement

/// Owns the AuthorizationRef behind an external form sent to the helper. The helper
/// rebuilds the authorization from that form, so the reference must stay alive until
/// the helper replies. `release()` runs after `send` completes; `deinit` is a fallback.
private final class AdministratorAuthorization: @unchecked Sendable {
    let externalForm: Data
    private var reference: AuthorizationRef?

    init(reference: AuthorizationRef, externalForm: Data) {
        self.reference = reference
        self.externalForm = externalForm
    }

    func release() {
        guard let reference else { return }
        self.reference = nil
        AuthorizationFree(reference, [])
    }

    deinit { release() }
}

actor PrivilegedProcessActionController: ProcessActioning {
    private let local = LocalProcessActionController()

    /// Finder belongs to the current user, so relaunching it never needs the helper.
    func relaunchFinder(identity: ProcessIdentity) async -> ProcessActionResult {
        await local.relaunchFinder(identity: identity)
    }

    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        let localResult = await local.terminate(identity: identity, force: force)
        guard case let .rejected(reason, _) = localResult.outcome,
              reason == .differentUser || reason == .permissionDenied else { return localResult }
        let target = HelperTargetIdentity(pid: identity.pid, seconds: identity.startTime.secondsSinceEpoch,
                                          microseconds: identity.startTime.microseconds)
        guard let observed = HelperTerminationPolicy.lookupTarget(pid: identity.pid) else {
            return ProcessActionResult(identity: identity, force: force,
                                       outcome: .rejected(.processExited, detail: "The target exited before administrator authorization."))
        }
        if let rejection = HelperTerminationPolicy.preflightRejection(observed: observed, requested: target,
                                                                      clientPID: Int32(getpid())) {
            let detail: String
            let actionRejection: ProcessActionRejection
            switch rejection {
            case .processExited:
                actionRejection = .processExited
                detail = "The target exited before administrator authorization."
            case .identityChanged:
                actionRejection = .identityChanged
                detail = "The target identity changed before administrator authorization."
            case .invalidIdentity:
                actionRejection = .invalidIdentity
                detail = "The target identity is invalid."
            case .currentProcess:
                actionRejection = .currentProcess
                detail = "The current application cannot terminate itself."
            case .pidOne:
                actionRejection = .pidOne
                detail = "The launchd process cannot be terminated."
            case .protectedProcess:
                actionRejection = .protectedProcess
                detail = "The target is protected or owned by root."
            }
            return ProcessActionResult(identity: identity, force: force,
                                       outcome: .rejected(actionRejection, detail: detail))
        }
        guard SMAppService.daemon(plistName: helperMachService + ".plist").status == .enabled,
              let requirement = SigningIdentity.requirement(for: helperSigningIdentifier) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.helperUnavailable, detail: "A signed and approved helper is required."))
        }
        guard let request = try? JSONEncoder().encode(HelperTerminationPayload(version: helperProtocolVersion, target: target, force: force)) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.helperUnavailable, detail: "Could not encode request."))
        }
        guard let authorization = await Self.authorize(pid: identity.pid) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.permissionDenied, detail: "Administrator authorization was not granted."))
        }
        let result = await Self.send(request, authorization: authorization.externalForm, requirement: requirement)
        // Used after the await so the reference stays alive until the helper has replied.
        authorization.release()
        let outcome: ProcessActionOutcome
        switch result {
        case "signalSent": outcome = .signalSent
        case "authorizationDenied": outcome = .rejected(.permissionDenied, detail: "Administrator authorization expired or was rejected.")
        case "targetRejected": outcome = .rejected(.protectedProcess, detail: "The target exited, changed identity, or is protected.")
        case "signalFailed": outcome = .rejected(.signalFailed, detail: "The helper could not signal the process.")
        default: outcome = .rejected(.helperUnavailable, detail: result)
        }
        return ProcessActionResult(identity: identity, force: force, outcome: outcome)
    }

    /// The Security dialog blocks until the user answers, so it runs off the main actor.
    nonisolated private static func authorize(pid: Int32) async -> AdministratorAuthorization? {
        await Task.detached(priority: .userInitiated) {
            PrivilegedProcessActionController.grantAdministratorAuthorization(pid: pid)
        }.value
    }

    nonisolated private static func grantAdministratorAuthorization(pid: Int32) -> AdministratorAuthorization? {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return nil }
        guard acquireAdministratorRight(reference, pid: pid) else {
            AuthorizationFree(reference, [])
            return nil
        }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            return nil
        }
        let form = withUnsafeBytes(of: &external) { Data($0) }
        return AdministratorAuthorization(reference: reference, externalForm: form)
    }

    /// Requests only the admin right; the environment prompt explains why the dialog appears.
    /// The prompt bytes and C key stay alive for the whole AuthorizationCopyRights call.
    nonisolated private static func acquireAdministratorRight(_ reference: AuthorizationRef, pid: Int32) -> Bool {
        var prompt = Array("Microgravity needs an administrator to quit “PID \(pid)”, which belongs to another user.".utf8)
        return prompt.withUnsafeMutableBytes { promptBytes in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                var environmentItem = AuthorizationItem(name: promptKey, valueLength: promptBytes.count,
                                                        value: promptBytes.baseAddress, flags: 0)
                return withUnsafeMutablePointer(to: &environmentItem) { environmentItems in
                    var environment = AuthorizationEnvironment(count: 1, items: environmentItems)
                    return "system.privilege.admin".withCString { name in
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &item) { items in
                            var rights = AuthorizationRights(count: 1, items: items)
                            return AuthorizationCopyRights(reference, &rights, &environment,
                                                           [.interactionAllowed, .extendRights], nil) == errAuthorizationSuccess
                        }
                    }
                }
            }
        }
    }

    private static func send(_ request: Data, authorization: Data, requirement: String) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            let reply = XPCSingleReply(continuation, connection: connection, timeout: 5,
                                       timeoutValue: "Helper connection timed out.")
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.interruptionHandler = { reply.finish("Helper connection interrupted.") }
            connection.invalidationHandler = { reply.finish("Helper connection invalidated.") }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish("Helper connection failed.") }) as? HelperProtocol else {
                reply.finish("Helper protocol unavailable."); return
            }
            proxy.terminate(request, authorization: authorization) { reply.finish($0) }
            // A hung helper must not leak the continuation forever; the first
            // finisher (reply, handler, timeout) wins.
            reply.armTimeout()
        }
    }
}
