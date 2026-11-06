import Foundation
import Security
import ServiceManagement

actor PrivilegedProcessActionController: ProcessActioning {
    private let local = LocalProcessActionController()
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        let localResult = await local.terminate(identity: identity, force: force)
        guard case let .rejected(reason, _) = localResult.outcome,
              reason == .differentUser || reason == .permissionDenied else { return localResult }
        guard SMAppService.daemon(plistName: helperMachService + ".plist").status == .enabled,
              let requirement = SigningIdentity.requirement(for: helperSigningIdentifier) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.helperUnavailable, detail: "A signed and approved helper is required."))
        }
        guard let authorization = await MainActor.run(body: { Self.authorize() }) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.permissionDenied, detail: "Administrator authorization was not granted."))
        }
        let target = HelperTargetIdentity(pid: identity.pid, seconds: identity.startTime.secondsSinceEpoch,
                                          microseconds: identity.startTime.microseconds)
        guard let request = try? JSONEncoder().encode(HelperTerminationPayload(version: helperProtocolVersion, target: target, force: force)) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.helperUnavailable, detail: "Could not encode request."))
        }
        let result = await Self.send(request, authorization: authorization, requirement: requirement)
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
    @MainActor private static func authorize() -> Data? {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return nil }
        defer { AuthorizationFree(reference, []) }
        let granted = "system.privilege.admin".withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [.interactionAllowed, .extendRights], nil) == errAuthorizationSuccess
            }
        }
        guard granted else { return nil }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else { return nil }
        return withUnsafeBytes(of: &external) { Data($0) }
    }
    private static func send(_ request: Data, authorization: Data, requirement: String) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            let reply = OneReply(continuation: continuation, connection: connection)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.interruptionHandler = { reply.finish("Helper connection interrupted.") }
            connection.invalidationHandler = { reply.finish("Helper connection invalidated.") }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish("Helper connection failed.") }) as? HelperProtocol else {
                reply.finish("Helper protocol unavailable."); return
            }
            proxy.terminate(request, authorization: authorization) { reply.finish($0) }
            // A hung helper must not leak the continuation forever.
            // OneReply.finish is lock-guarded and invalidates the
            // connection, so the first finisher (reply, handler, timeout)
            // wins and later finishers are no-ops.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { reply.finish("Helper connection timed out.") }
        }
    }
}

private final class OneReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private let connection: NSXPCConnection
    init(continuation: CheckedContinuation<String, Never>, connection: NSXPCConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ value: String) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        guard let saved else { return }
        connection.invalidate()
        saved.resume(returning: value)
    }
}
