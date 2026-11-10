import Foundation
import os

/// NSXPC passes this block as the response endpoint for an asynchronous exported
/// method. SamplingRunner invokes it once on its serial queue; it carries no helper
/// state, and XPC transports the reply to the caller. Keep this unchecked bridge at
/// the Objective-C/XPC boundary rather than erasing Sendable on SamplingRunner's API.
private final class XPCSampleReply: @unchecked Sendable {
    private let handler: (Data) -> Void

    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }

    func send(_ data: Data) { handler(data) }
}

/// Audit log. Logs only non-secret identifiers and outcomes; authorization bytes are never logged.
enum HelperLog {
    static let connection = Logger(subsystem: helperMachService, category: "connection")
    static let terminate = Logger(subsystem: helperMachService, category: "terminate")
    static let sample = Logger(subsystem: helperMachService, category: "sample")
}

final class Service: NSObject, HelperProtocol {
    let cancellation = SamplingCancellation()
    let clientPID: Int32
    let clientUID: uid_t
    private let lock = NSLock()
    private var verified = false
    private var connected = true
    private let idle: Lifecycle
    init(clientPID: Int32, clientUID: uid_t, idle: Lifecycle) {
        self.clientPID = clientPID; self.clientUID = clientUID; self.idle = idle
    }

    /// NSXPC dispatches a message only after the peer meets the code-signing requirement,
    /// so the first message marks the peer verified. Only verified peers keep the helper
    /// alive; a process that connects and never sends anything cannot pin it.
    private func markVerified() {
        lock.lock(); defer { lock.unlock() }
        guard connected, !verified else { return }
        verified = true
        idle.peerVerified()
        HelperLog.connection.info("connection verified client pid=\(self.clientPID, privacy: .public) uid=\(self.clientUID, privacy: .public)")
    }
    /// Called from the invalidation handler. Both updates run under `lock`, so a peer is
    /// counted and released exactly once.
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        guard connected else { return }
        connected = false
        if verified { idle.peerClosed() }
    }
    var isVerified: Bool { lock.lock(); defer { lock.unlock() }; return verified }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    func sample(_ data: Data, reply: @escaping (Data) -> Void) {
        markVerified()
        guard data.count <= 4096, let request = try? JSONDecoder().decode(HelperSampleRequest.self, from: data) else {
            HelperLog.sample.error("sample rejected client pid=\(self.clientPID, privacy: .public) kind=undecodable")
            reply(Data())
            return
        }
        let xpcReply = XPCSampleReply(reply)
        let pid = clientPID
        SamplingRunner.shared.sample(request, cancellation: cancellation) { response in
            let result = response.error ?? "ok"
            HelperLog.sample.info("sample client pid=\(pid, privacy: .public) kind=\(request.kind.rawValue, privacy: .public) result=\(result, privacy: .public)")
            xpcReply.send((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func terminate(_ request: Data, authorization: Data, reply: @escaping (String) -> Void) {
        markVerified()
        // Best-effort decode for logging only, under the same size bound as the real
        // validation in TerminationService.
        let decoded = request.count <= 4096 ? try? JSONDecoder().decode(HelperTerminationPayload.self, from: request) : nil
        let requested = decoded.map { "pid=\($0.target.pid) force=\($0.force)" } ?? "undecodable"
        let result = TerminationService.perform(request, authorization: authorization, clientPID: clientPID,
                                                clientConnected: { [weak self] in self?.isConnected ?? false })
        HelperLog.terminate.info("terminate client pid=\(self.clientPID, privacy: .public) uid=\(self.clientUID, privacy: .public) requested=\(requested, privacy: .public) result=\(result, privacy: .public)")
        reply(result)
    }
    func capabilities(_ reply: @escaping (Int, [String]) -> Void) {
        markVerified()
        let tools: [(String, String)] = [("nettop", "/usr/bin/nettop"), ("powermetrics", "/usr/bin/powermetrics")]
        reply(helperProtocolVersion, tools.filter { FileManager.default.isExecutableFile(atPath: $0.1) }.map { $0.0 })
    }
}

/// The helper executable as found on disk. Sparkle replaces the whole app bundle, so a
/// changed device, inode, size or modification time means this process runs old code.
struct ExecutableSnapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let seconds: Int
    let nanoseconds: Int

    static func ownPath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
    static func current(path: String) -> ExecutableSnapshot? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ExecutableSnapshot(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                                  seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// Decides when the helper exits so launchd starts the current on-disk binary on the next
/// connection:
/// - Idle: 30 s after the last verified peer closes, unless a consumed authorization is
///   still unexpired (that single-use store is in memory).
/// - Stale: as soon as no verified peer remains after the on-disk executable changed
///   (a Sparkle update). The app reconnects at least every 5 s, so idle exit alone would
///   keep old code running. A stale helper also refuses new connections. It does not wait
///   for consumed authorizations: every termination prompts again, so a reused form can
///   only show another dialog.
final class Lifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "run.rosie.microgravity.helper.lifecycle")
    private let idleInterval: TimeInterval = 30
    private let staleCheckInterval: TimeInterval = 5
    private let executablePath: String?
    private let startupSnapshot: ExecutableSnapshot?
    private var verifiedPeers = 0
    private var generation = 0
    private var stale = false

    init() {
        executablePath = ExecutableSnapshot.ownPath()
        startupSnapshot = executablePath.flatMap { ExecutableSnapshot.current(path: $0) }
        if startupSnapshot == nil {
            HelperLog.connection.error("executable snapshot unavailable; update detection disabled, idle exit only")
        }
    }

    func start() {
        lock.lock()
        scheduleIdleLocked()
        lock.unlock()
        scheduleStaleCheck()
    }

    func peerVerified() {
        lock.lock(); defer { lock.unlock() }
        verifiedPeers += 1
        generation += 1
    }

    func peerClosed() {
        lock.lock(); defer { lock.unlock() }
        verifiedPeers -= 1
        guard verifiedPeers == 0 else { return }
        exitIfDrainedLocked()
        scheduleIdleLocked()
    }

    /// True once the on-disk executable differs from startup. Exits right away if no
    /// verified peer remains.
    func refuseIfStale() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard refreshStaleLocked() else { return false }
        exitIfDrainedLocked()
        return true
    }

    private func refreshStaleLocked() -> Bool {
        if !stale, let executablePath, let startupSnapshot,
           ExecutableSnapshot.current(path: executablePath) != startupSnapshot {
            stale = true
            HelperLog.connection.info("helper executable changed on disk; draining")
        }
        return stale
    }

    // Caller holds lock.
    private func exitIfDrainedLocked() {
        guard stale, verifiedPeers == 0 else { return }
        HelperLog.connection.info("stale exit: helper executable changed on disk")
        exit(0)
    }

    private func scheduleStaleCheck() {
        queue.asyncAfter(deadline: .now() + staleCheckInterval) { [self] in
            if refuseIfStale() { return }
            scheduleStaleCheck()
        }
    }

    // Caller holds lock. Bumping the generation makes any earlier scheduled check a no-op.
    private func scheduleIdleLocked() {
        generation += 1
        let expected = generation
        queue.asyncAfter(deadline: .now() + idleInterval) { self.idleCheck(expected) }
    }

    private func idleCheck(_ expected: Int) {
        lock.lock(); defer { lock.unlock() }
        guard expected == generation, verifiedPeers == 0 else { return }
        if TerminationService.hasUnexpiredConsumedAuthorizations() {
            scheduleIdleLocked()
            return
        }
        HelperLog.connection.info("idle exit: no verified client connections")
        exit(0)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    private let requirement: String?
    private let lifecycle: Lifecycle
    /// A peer that has not sent a valid message by then is disconnected.
    private let verificationTimeout: TimeInterval = 10
    init(requirement: String?, lifecycle: Lifecycle) { self.requirement = requirement; self.lifecycle = lifecycle }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            HelperLog.connection.error("connection rejected: signing requirement unavailable client pid=\(connection.processIdentifier, privacy: .public)")
            return false
        }
        guard !lifecycle.refuseIfStale() else {
            HelperLog.connection.info("connection rejected: helper executable changed on disk client pid=\(connection.processIdentifier, privacy: .public)")
            return false
        }
        // The requirement is enforced when the first message arrives, not here. Until then
        // the peer is unverified and does not count toward the helper's lifetime.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        // Defense in depth only: connection.processIdentifier is a bare PID that the OS
        // can reuse after the client exits. It is used solely to refuse self-termination.
        // The code-signing requirement above is the real gate on who may connect. Do not
        // widen what clientPID authorizes; if it must, capture the audit token or the
        // PID plus start time at connect time instead.
        let service = Service(clientPID: connection.processIdentifier, clientUID: connection.effectiveUserIdentifier,
                              idle: lifecycle)
        connection.exportedObject = service
        connection.invalidationHandler = {
            HelperLog.connection.info("connection invalidated client pid=\(service.clientPID, privacy: .public)")
            service.cancellation.cancel()
            service.disconnect()
        }
        HelperLog.connection.info("connection opened client pid=\(service.clientPID, privacy: .public) uid=\(service.clientUID, privacy: .public)")
        connection.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + verificationTimeout) {
            guard !service.isVerified, service.isConnected else { return }
            HelperLog.connection.info("connection closed: no verified message client pid=\(service.clientPID, privacy: .public)")
            connection.invalidate()
        }
        return true
    }
}

// Computed once at startup and reused for every connection: after a Sparkle update
// replaces the bundle on disk, re-reading the on-disk signature per connection can fail.
let listenerRequirement = SigningIdentity.requirement(for: appSigningIdentifier)
if listenerRequirement == nil {
    HelperLog.connection.error("signing requirement unavailable at startup; all connections will be rejected")
}
let lifecycle = Lifecycle()
let listener = NSXPCListener(machServiceName: helperMachService)
let delegate = Listener(requirement: listenerRequirement, lifecycle: lifecycle)
listener.delegate = delegate
lifecycle.start()
listener.resume()
RunLoop.current.run()
