import Darwin
import Foundation

struct HelperTarget: Codable, Equatable {
    let pid: Int32
    let seconds: Int64
    let microseconds: Int32
    let owner: UInt32
    let protected: Bool
}

enum HelperPreflightRejection: Equatable {
    case processExited
    case identityChanged
    case invalidIdentity
    case currentProcess
    case pidOne
    case protectedProcess
}

enum HelperTerminationPolicy {
    /// OS-owned executable locations. Shared by the app and the helper so both apply one rule.
    static let protectedPathPrefixes = ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    /// A process is protected when the kernel marks it as a system process, when its
    /// executable lies under a protected prefix, or when its executable cannot be read
    /// (ownership cannot be ruled out).
    static func isProtected(executablePath: String?, systemFlag: Bool) -> Bool {
        guard let executablePath, !executablePath.isEmpty else { return true }
        return systemFlag || protectedPathPrefixes.contains { executablePath.hasPrefix($0) }
    }

    /// Reads identity, owner, and protection for a live PID without requiring privilege.
    /// Start time and owner come from calls that succeed for every process as a non-root
    /// caller; `proc_pidinfo(PROC_PIDTBSDINFO)` fails with EPERM for other users' processes.
    /// Returns nil when the PID does not exist.
    static func lookupTarget(pid: Int32) -> HelperTarget? {
        guard pid > 0, let before = kernelRecord(pid: pid) else { return nil }
        var short = proc_bsdshortinfo()
        guard proc_pidinfo(pid_t(pid), PROC_PIDT_SHORTBSDINFO, 0, &short,
                           Int32(MemoryLayout<proc_bsdshortinfo>.size)) == MemoryLayout<proc_bsdshortinfo>.size else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        let path: String? = pathLength > 0 ? String(cString: buffer) : nil
        // The fields above come from separate calls. Re-read the start time so a PID reused between them
        // cannot combine one process's identity with another's owner or path.
        guard let after = kernelRecord(pid: pid),
              after.kp_proc.p_starttime.tv_sec == before.kp_proc.p_starttime.tv_sec,
              after.kp_proc.p_starttime.tv_usec == before.kp_proc.p_starttime.tv_usec else { return nil }
        let systemFlag = (short.pbsi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0
        let start = before.kp_proc.p_starttime
        // A process whose real or saved UID is root can regain root, so any root UID makes it root-owned.
        let uids = [short.pbsi_uid, short.pbsi_ruid, short.pbsi_svuid]
        let owner = uids.contains(0) ? 0 : short.pbsi_uid
        return HelperTarget(pid: pid, seconds: Int64(start.tv_sec), microseconds: Int32(start.tv_usec),
                            owner: owner,
                            protected: isProtected(executablePath: path, systemFlag: systemFlag))
    }

    private static func kernelRecord(pid: Int32) -> kinfo_proc? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &kinfo, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, kinfo.kp_proc.p_pid == pid else { return nil }
        return kinfo
    }

    static func permits(_ observed: HelperTarget, requested: HelperTarget, clientPID: Int32, helperPID: Int32) -> Bool {
        observed.pid > 1 && observed.seconds > 0 && (0..<1_000_000).contains(observed.microseconds) &&
        observed.pid != clientPID && observed.pid != helperPID &&
        observed.pid == requested.pid && observed.seconds == requested.seconds &&
        observed.microseconds == requested.microseconds && observed.owner != 0 && !observed.protected
    }

    static func preflightRejection(observed: HelperTarget?, requested: HelperTargetIdentity,
                                   clientPID: Int32) -> HelperPreflightRejection? {
        guard let observed else { return .processExited }
        let policyTarget = HelperTarget(pid: requested.pid, seconds: requested.seconds,
                                        microseconds: requested.microseconds,
                                        owner: observed.owner, protected: observed.protected)
        let policyPermits = permits(observed, requested: policyTarget,
                                    clientPID: clientPID, helperPID: -1)
        guard observed.pid == requested.pid,
              observed.seconds == requested.seconds,
              observed.microseconds == requested.microseconds else { return .identityChanged }
        guard observed.seconds > 0, (0..<1_000_000).contains(observed.microseconds) else { return .invalidIdentity }
        guard observed.pid > 1 else { return .pidOne }
        guard observed.pid != clientPID else { return .currentProcess }
        guard observed.owner != 0, !observed.protected else { return .protectedProcess }
        return policyPermits ? nil : .protectedProcess
    }
}
