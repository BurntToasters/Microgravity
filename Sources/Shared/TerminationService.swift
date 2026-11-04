import Darwin
import Foundation
import Security

// Only an already-authorized admin right is accepted; this process never prompts.
enum TerminationService {
    static func perform(_ data: Data, authorization: Data, clientPID: Int32) -> String {
        guard data.count <= 4096, authorization.count == MemoryLayout<AuthorizationExternalForm>.size,
              let request = try? JSONDecoder().decode(HelperTerminationRequest.self, from: data),
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
        guard let initial = lookup(request.target.pid),
              HelperTerminationPolicy.permits(initial, requested: request.target, clientPID: clientPID, helperPID: getpid()),
              let final = lookup(request.target.pid), final == initial,
              HelperTerminationPolicy.permits(final, requested: request.target, clientPID: clientPID, helperPID: getpid()) else { return "targetRejected" }
        return kill(pid_t(final.pid), request.force ? SIGKILL : SIGTERM) == 0 ? "signalSent" : "signalFailed"
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
