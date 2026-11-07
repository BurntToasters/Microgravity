import Darwin
import Foundation
import Security
import ServiceManagement

actor PrivilegedProcessActionController: ProcessActioning {
    private let local = LocalProcessActionController()
    func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        let localResult = await local.terminate(identity: identity, force: force)
        guard case let .rejected(reason, _) = localResult.outcome,
              reason == .differentUser || reason == .permissionDenied else { return localResult }
        let target = HelperTargetIdentity(pid: identity.pid, seconds: identity.startTime.secondsSinceEpoch,
                                          microseconds: identity.startTime.microseconds)
        guard let observed = Self.observeTarget(pid: identity.pid) else {
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
        guard let authorization = await MainActor.run(body: { Self.authorize() }) else {
            return ProcessActionResult(identity: identity, force: force, outcome: .rejected(.permissionDenied, detail: "Administrator authorization was not granted."))
        }
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

    private static func observeTarget(pid: Int32) -> HelperTarget? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid_t(pid), &path, UInt32(path.count))
        let executable = pathLength > 0 ? String(cString: path) : ""
        let protectedPath = executable.isEmpty
            || ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { executable.hasPrefix($0) }
        return HelperTarget(pid: pid,
                            seconds: Int64(info.pbi_start_tvsec),
                            microseconds: Int32(info.pbi_start_tvusec),
                            owner: UInt32(info.pbi_uid),
                            protected: protectedPath || (info.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0)
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

