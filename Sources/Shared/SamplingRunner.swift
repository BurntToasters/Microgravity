import Darwin
import Foundation

/// Shared cancellation state. Every field is protected by `lock`; handlers are
/// removed under the lock before invocation, so each registration runs at most once.
final class SamplingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var active: SampledChild?
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    func onCancel(_ id: UUID, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers[id] = handler
        lock.unlock()
    }
    func removeHandler(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
    func attach(_ child: SampledChild) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        active = child
        return true
    }
    func detach() { lock.lock(); active = nil; lock.unlock() }
    func cancel() {
        lock.lock()
        cancelled = true
        // kill() only signals an unreaped child, so a late cancel cannot hit a reused PID.
        active?.kill()
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// A sampling child launched with posix_spawn and reaped only by this class. The helper must own
/// reaping: Foundation's Process reaps on its own thread, so a PID could be reaped and reused between
/// an isRunning check and kill(), and root would SIGKILL an unrelated process. Here kill() signals only
/// an unreaped child. An exited-but-unreaped zombie still holds its PID, so signaling it is harmless.
final class SampledChild: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var reaped = false
    private var status: Int32 = 0
    private init(pid: pid_t) { self.pid = pid }

    /// Runs `command` with only PATH and LC_ALL set, working directory "/", stdin and stderr on
    /// /dev/null, stdout on `output`, and no other inherited descriptors. Returns nil if spawn fails.
    static func launch(_ command: SamplingRunner.Command, output: Int32) -> SampledChild? {
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, output, 1) == 0,
              posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0) == 0,
              setRootWorkingDirectory(&fileActions) else { return nil }
        let argv = cStrings([command.executable] + command.arguments)
        let envp = cStrings(["PATH=/usr/bin:/bin", "LC_ALL=C"])
        defer { for case let string? in argv + envp { free(string) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, command.executable, &fileActions, &attributes, argv, envp) == 0 else { return nil }
        return SampledChild(pid: pid)
    }
    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] { values.map { strdup($0) } + [nil] }
    /// addchdir_np is deprecated in the macOS 26 SDK (warnings are errors here), so on older systems
    /// it is looked up at runtime; macOS 26+ uses the replacement directly.
    private static func setRootWorkingDirectory(_ fileActions: inout posix_spawn_file_actions_t?) -> Bool {
        if #available(macOS 26.0, *) { return posix_spawn_file_actions_addchdir(&fileActions, "/") == 0 }
        typealias AddChdir = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t?>, UnsafePointer<CChar>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawn_file_actions_addchdir_np") else { return false }
        return unsafeBitCast(symbol, to: AddChdir.self)(&fileActions, "/") == 0
    }

    /// Sends SIGKILL only if the child has not been reaped. Returns whether a signal was sent.
    @discardableResult
    func kill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }
    /// Non-blocking reap. Returns true once the child has exited and been reaped.
    func pollExit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped { return true }
        var state: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &state, WNOHANG) } while result == -1 && errno == EINTR
        guard result != 0 else { return false }
        reaped = true
        // waitpid failing (e.g. ECHILD) also ends ownership; record a failure so the child is never signaled again.
        status = result == pid ? state : -1
        return true
    }
    /// Blocks until reaped. Reaping happens only under `lock`, so this cannot race kill().
    func waitForExit() {
        while !pollExit() { usleep(1_000) }
    }
    /// True only for a reaped child that exited with status 0 (nonzero exit or signal is false).
    var exitedCleanly: Bool { lock.lock(); defer { lock.unlock() }; return reaped && status == 0 }
}

/// Runner state is confined to `queue`, except admission state, which is guarded by
/// `admissionLock`. The command and other configuration are immutable after init.
final class SamplingRunner: @unchecked Sendable {
    static let shared = SamplingRunner()
    private let queue = DispatchQueue(label: "run.rosie.microgravity.sampling")
    private var lastStart: [HelperSampleKind: UInt64] = [:]
    private let admissionLock = NSLock()
    private var active = false
    private var pending: [Work] = []
    private struct Work: Sendable {
        let id: UUID
        let request: HelperSampleRequest
        let cancellation: SamplingCancellation
        let reply: @Sendable (HelperSampleResponse) -> Void
    }
    private func response(_ request: HelperSampleRequest, _ output: Data? = nil, _ error: String? = nil) -> HelperSampleResponse {
        HelperSampleResponse(version: helperProtocolVersion, kind: request.kind, capturedAt: Date(), output: output, error: error)
    }
    private func cancelPending(_ id: UUID) {
        admissionLock.lock()
        let index = pending.firstIndex { $0.id == id }
        let work = index.map { pending.remove(at: $0) }
        admissionLock.unlock()
        if let work { work.reply(response(work.request, nil, "disconnected")) }
    }
    private func finish(_ work: Work, _ output: Data?, _ error: String?) {
        work.cancellation.removeHandler(work.id)
        admissionLock.lock()
        active = false
        let next: Work? = pending.isEmpty ? nil : pending.removeFirst()
        if next != nil { active = true }
        admissionLock.unlock()
        if let next { execute(next) }
        work.reply(response(work.request, output, error))
    }
    struct Command: Sendable { let executable: String; let arguments: [String] }
    private let command: @Sendable (HelperSampleKind) -> Command
    private let outputLimit: Int
    private let timeoutNanoseconds: UInt64
    private let intervalNanoseconds: UInt64
    init(command: @escaping @Sendable (HelperSampleKind) -> Command = { SamplingRunner.fixedCommand($0) },
         outputLimit: Int = HelperSampleResponse.maximumOutputBytes,
         timeoutNanoseconds: UInt64 = 10_000_000_000,
         intervalNanoseconds: UInt64 = 5_000_000_000) {
        self.command = command
        self.outputLimit = min(max(0, outputLimit), HelperSampleResponse.maximumOutputBytes)
        self.timeoutNanoseconds = timeoutNanoseconds
        self.intervalNanoseconds = intervalNanoseconds
    }
    static func fixedCommand(_ kind: HelperSampleKind) -> Command {
        switch kind {
        case .nettop: return Command(executable: "/usr/bin/nettop", arguments: ["-n", "-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"])
        case .powermetrics: return Command(executable: "/usr/bin/powermetrics", arguments: ["-f", "plist", "-i", "1000", "-n", "1", "-s", "cpu_power,gpu_power"])
        }
    }

    func sample(_ request: HelperSampleRequest, cancellation: SamplingCancellation,
                reply: @escaping @Sendable (HelperSampleResponse) -> Void) {
        guard request.version == helperProtocolVersion else { reply(response(request, nil, "incompatibleVersion")); return }
        guard !cancellation.isCancelled else { reply(response(request, nil, "disconnected")); return }
        let work = Work(id: UUID(), request: request, cancellation: cancellation, reply: reply)
        admissionLock.lock()
        // Bounded admission: at most one active sample plus two pending,
        // enforced under this lock. Every acquired slot either sets
        // active = true (starts now) or appends exactly one pending entry,
        // and finish()/cancelPending() release exactly one slot, so the
        // queue can never grow unboundedly under concurrent calls.
        if active && pending.count >= 2 {
            admissionLock.unlock()
            reply(response(request, nil, "busy")); return
        }
        let startsNow = !active
        if startsNow { active = true } else { pending.append(work) }
        admissionLock.unlock()
        cancellation.onCancel(work.id) { [weak self] in self?.cancelPending(work.id) }
        if startsNow { execute(work) }
    }
    private func execute(_ work: Work) {
        queue.async {
            let request = work.request
            let cancellation = work.cancellation
            let now = DispatchTime.now().uptimeNanoseconds
            let kind = request.kind
            func result(_ output: Data? = nil, _ error: String? = nil) {
                self.finish(work, output, error)
            }
            guard request.version == helperProtocolVersion else { result(nil, "incompatibleVersion"); return }
            guard !cancellation.isCancelled else { result(nil, "disconnected"); return }
            if let last = self.lastStart[kind], now >= last, now - last < self.intervalNanoseconds {
                result(nil, "rateLimited"); return
            }
            self.lastStart[kind] = now
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { result(nil, "launchFailed"); return }
            let readFD = fds[0], writeFD = fds[1]
            _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
            defer { close(readFD) }
            guard let child = SampledChild.launch(self.command(kind), output: writeFD) else {
                close(writeFD); result(nil, "launchFailed"); return
            }
            close(writeFD)
            defer { cancellation.detach() }
            guard cancellation.attach(child) else { child.kill(); child.waitForExit(); result(nil, "disconnected"); return }
            let flags = fcntl(readFD, F_GETFL)
            _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
            var output = Data()
            var failure: String?
            let deadline = DispatchTime.now().uptimeNanoseconds &+ self.timeoutNanoseconds
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = read(readFD, &buffer, buffer.count)
                if count > 0 {
                    if output.count + count > self.outputLimit {
                        failure = "outputLimit"; break
                    }
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 && child.pollExit() { break }
                else if count < 0 && errno != EAGAIN && errno != EINTR { failure = "readFailed"; break }
                if cancellation.isCancelled { failure = "disconnected"; break }
                if DispatchTime.now().uptimeNanoseconds >= deadline { failure = "timedOut"; break }
                if count <= 0 { usleep(10_000) }
            }
            if failure == nil && cancellation.isCancelled { failure = "disconnected" }
            if failure != nil { child.kill() }
            child.waitForExit()
            if let failure { result(nil, failure) }
            else if !child.exitedCleanly { result(nil, "commandFailed") }
            else if output.isEmpty { result(nil, "noData") }
            else { result(output) }
        }
    }
}
