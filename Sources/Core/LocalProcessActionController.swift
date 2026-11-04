import AppKit
import Darwin
import Foundation

struct ProcessControlTarget: Sendable {
    let identity: ProcessIdentity
    let ownerUID: UInt32
    let isProtected: Bool
}

/// Sends signals only to the current user's live process after re-reading PID,
/// start time, owner, and the OS protected-process flag immediately beforehand.
public actor LocalProcessActionController: ProcessActioning {
    typealias TargetLookup = @Sendable (Int32) -> ProcessControlTarget?
    typealias SignalSender = @Sendable (Int32, Int32) -> Int32
    typealias AppTerminator = @MainActor @Sendable (Int32) -> Bool?

    private let currentUID: UInt32
    private let ownPID: Int32
    private let targetLookup: TargetLookup
    private let signalSender: SignalSender
    private let appTerminator: AppTerminator

    public init() {
        currentUID = UInt32(getuid())
        ownPID = Int32(getpid())
        targetLookup = { Self.lookupTarget($0) }
        signalSender = { Self.sendSignal($0, $1) }
        appTerminator = { pid in
            guard let application = NSRunningApplication(processIdentifier: pid), application.bundleURL != nil else { return nil }
            return application.terminate()
        }
    }

    init(currentUID: UInt32, ownPID: Int32, targetLookup: @escaping TargetLookup,
         signalSender: @escaping SignalSender, appTerminator: @escaping AppTerminator = { _ in nil }) {
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.targetLookup = targetLookup
        self.signalSender = signalSender
        self.appTerminator = appTerminator
    }

    public func terminate(identity: ProcessIdentity, force: Bool) async -> ProcessActionResult {
        guard identity.pid > 0 else { return rejected(identity, force, .invalidIdentity) }
        if identity.pid == 1 { return rejected(identity, force, .pidOne) }
        if identity.pid == ownPID { return rejected(identity, force, .currentProcess) }

        guard let target = targetLookup(identity.pid) else {
            return rejected(identity, force, .processExited)
        }
        guard target.identity == identity else { return rejected(identity, force, .identityChanged) }
        guard target.ownerUID == currentUID else { return rejected(identity, force, .differentUser) }
        guard !target.isProtected else { return rejected(identity, force, .protectedProcess) }

        // Revalidate once more at the signal boundary to narrow the PID-reuse race.
        guard let current = targetLookup(identity.pid) else {
            return rejected(identity, force, .processExited)
        }
        guard current.identity == identity else { return rejected(identity, force, .identityChanged) }
        guard current.ownerUID == currentUID else { return rejected(identity, force, .differentUser) }
        guard !current.isProtected else { return rejected(identity, force, .protectedProcess) }

        if !force {
            let lookup = targetLookup
            let uid = currentUID
            let terminateApp = appTerminator
            let result: (ProcessActionRejection?, Bool?) = await MainActor.run {
                guard let latest = lookup(identity.pid) else { return (.processExited, nil) }
                guard latest.identity == identity else { return (.identityChanged, nil) }
                guard latest.ownerUID == uid else { return (.differentUser, nil) }
                guard !latest.isProtected else { return (.protectedProcess, nil) }
                return (nil, terminateApp(identity.pid))
            }
            if let rejection = result.0 { return rejected(identity, force, rejection) }
            if let accepted = result.1 {
                return accepted ? ProcessActionResult(identity: identity, force: force, outcome: .signalSent)
                    : rejected(identity, force, .signalFailed, detail: "The application did not accept the quit request.")
            }
            // The main-thread hop may have delayed the CLI fallback.
            guard let latest = targetLookup(identity.pid) else { return rejected(identity, force, .processExited) }
            guard latest.identity == identity else { return rejected(identity, force, .identityChanged) }
            guard latest.ownerUID == currentUID else { return rejected(identity, force, .differentUser) }
            guard !latest.isProtected else { return rejected(identity, force, .protectedProcess) }
        }

        let signal = force ? SIGKILL : SIGTERM
        guard signalSender(identity.pid, Int32(signal)) == 0 else {
            let reason: ProcessActionRejection = errno == EPERM ? .permissionDenied : .signalFailed
            return rejected(identity, force, reason, detail: String(cString: strerror(errno)))
        }
        return ProcessActionResult(identity: identity, force: force, outcome: .signalSent)
    }

    private func rejected(_ identity: ProcessIdentity, _ force: Bool,
                          _ reason: ProcessActionRejection, detail: String? = nil) -> ProcessActionResult {
        ProcessActionResult(identity: identity, force: force, outcome: .rejected(reason, detail: detail))
    }

    private static func lookupTarget(_ pid: Int32) -> ProcessControlTarget? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let result = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info,
                                  Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let start = ProcessStartTime(secondsSinceEpoch: Int64(info.pbi_start_tvsec),
                                     microseconds: Int32(info.pbi_start_tvusec))
        let path = executablePath(pid)
        let systemFlag = UInt32(PROC_FLAG_SYSTEM)
        let systemLocation = path.map {
            $0.hasPrefix("/System/Library/")
                || $0.hasPrefix("/usr/libexec/") || $0.hasPrefix("/usr/sbin/")
                || $0.hasPrefix("/sbin/")
        } ?? false
        return ProcessControlTarget(identity: ProcessIdentity(pid: pid, startTime: start),
                                    ownerUID: UInt32(info.pbi_uid),
                                    isProtected: (info.pbi_flags & systemFlag) != 0 || systemLocation)
    }

    private static func sendSignal(_ pid: Int32, _ signal: Int32) -> Int32 {
        kill(pid_t(pid), signal)
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }
}
