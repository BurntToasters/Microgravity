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
    /// Quits and reopens the Finder process with the given PID. Returns a rejection detail on failure.
    typealias FinderRelauncher = @Sendable (Int32) async -> String?

    private let currentUID: UInt32
    private let ownPID: Int32
    private let targetLookup: TargetLookup
    private let signalSender: SignalSender
    private let appTerminator: AppTerminator
    private let finderRelauncher: FinderRelauncher

    public init() {
        currentUID = UInt32(getuid())
        ownPID = Int32(getpid())
        targetLookup = { Self.lookupTarget($0) }
        signalSender = { Self.sendSignal($0, $1) }
        appTerminator = { pid in
            guard let application = NSRunningApplication(processIdentifier: pid), application.bundleURL != nil else { return nil }
            return application.terminate()
        }
        finderRelauncher = { await Self.relaunchFinderApplication(pid: $0) }
    }

    init(currentUID: UInt32, ownPID: Int32, targetLookup: @escaping TargetLookup,
         signalSender: @escaping SignalSender, appTerminator: @escaping AppTerminator = { _ in nil },
         finderRelauncher: @escaping FinderRelauncher = { _ in "Relaunching Finder is not available." }) {
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.targetLookup = targetLookup
        self.signalSender = signalSender
        self.appTerminator = appTerminator
        self.finderRelauncher = finderRelauncher
    }

    /// Finder is protected from signals by its system location. Relaunch revalidates the full identity and
    /// owner, then quits Finder through AppKit and opens it again; no signal is sent by PID.
    public func relaunchFinder(identity: ProcessIdentity) async -> ProcessActionResult {
        guard identity.pid > 1 else { return rejected(identity, false, .invalidIdentity) }
        guard let target = targetLookup(identity.pid) else { return rejected(identity, false, .processExited) }
        guard target.identity == identity else { return rejected(identity, false, .identityChanged) }
        guard target.ownerUID == currentUID else { return rejected(identity, false, .differentUser) }
        if let failure = await finderRelauncher(identity.pid) {
            return rejected(identity, false, .signalFailed, detail: failure)
        }
        return ProcessActionResult(identity: identity, force: false, outcome: .signalSent)
    }

    /// Asks Finder to quit, force quits it if it has not quit within 5 seconds, and opens it again if the
    /// system has not already relaunched it. The PID must belong to the Finder bundle in its system location.
    @MainActor
    static func relaunchFinderApplication(pid: Int32) async -> String? {
        guard let finder = NSRunningApplication(processIdentifier: pid),
              finder.bundleIdentifier == FinderProcess.bundleIdentifier,
              finder.bundleURL?.standardizedFileURL.path == FinderProcess.applicationPath else {
            return "The selected process is not Finder."
        }
        if !finder.terminate() { _ = finder.forceTerminate() }
        if !(await waitUntil(seconds: 5) { finder.isTerminated }) {
            _ = finder.forceTerminate()
            guard await waitUntil(seconds: 2, { finder.isTerminated }) else { return "Finder did not quit." }
        }
        // The system usually reopens Finder itself; open it only if that has not happened.
        let relaunched = await waitUntil(seconds: 2) {
            !NSRunningApplication.runningApplications(withBundleIdentifier: FinderProcess.bundleIdentifier).isEmpty
        }
        if relaunched { return nil }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: FinderProcess.applicationPath),
                                                             configuration: NSWorkspace.OpenConfiguration())
            return nil
        } catch {
            return "Finder quit but could not be opened again: \(error.localizedDescription)"
        }
    }

    @MainActor
    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
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
        let status = signalSender(identity.pid, signal)
        // Capture errno before anything else can overwrite it.
        let failure = errno
        guard status == 0 else {
            let reason: ProcessActionRejection = failure == EPERM ? .permissionDenied : .signalFailed
            return rejected(identity, force, reason, detail: String(cString: strerror(failure)))
        }
        return ProcessActionResult(identity: identity, force: force, outcome: .signalSent)
    }

    private func rejected(_ identity: ProcessIdentity, _ force: Bool,
                          _ reason: ProcessActionRejection, detail: String? = nil) -> ProcessActionResult {
        ProcessActionResult(identity: identity, force: force, outcome: .rejected(reason, detail: detail))
    }

    private static func lookupTarget(_ pid: Int32) -> ProcessControlTarget? {
        guard let target = HelperTerminationPolicy.lookupTarget(pid: pid) else { return nil }
        let start = ProcessStartTime(secondsSinceEpoch: target.seconds, microseconds: target.microseconds)
        return ProcessControlTarget(identity: ProcessIdentity(pid: pid, startTime: start),
                                    ownerUID: target.owner,
                                    isProtected: target.protected)
    }

    private static func sendSignal(_ pid: Int32, _ signal: Int32) -> Int32 {
        kill(pid_t(pid), signal)
    }
}
