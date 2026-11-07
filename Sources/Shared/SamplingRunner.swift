import Darwin
import Foundation

/// Shared cancellation state. Every field is protected by `lock`; handlers are
/// removed under the lock before invocation, so each registration runs at most once.
final class SamplingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var active: Process?
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    func onCancel(_ id: UUID, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers[id] = handler
        lock.unlock()
    }
    func removeHandler(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        active = process
        return true
    }
    func detach() { lock.lock(); active = nil; lock.unlock() }
    func cancel() {
        lock.lock()
        cancelled = true
        let process = active
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
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
        case .powermetrics: return Command(executable: "/usr/bin/powermetrics", arguments: ["-f", "plist", "-i", "1000", "-n", "1", "-s", "tasks,cpu_power,gpu_power", "--show-process-gpu"])
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
            let process = Process()
            let command = self.command(kind)
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard cancellation.attach(process) else { result(nil, "disconnected"); return }
            defer { cancellation.detach(); try? pipe.fileHandleForReading.close() }
            do { try process.run() } catch { result(nil, "launchFailed"); return }
            try? pipe.fileHandleForWriting.close()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var output = Data()
            var failure: String?
            let deadline = DispatchTime.now().uptimeNanoseconds &+ self.timeoutNanoseconds
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    if output.count + count > self.outputLimit {
                        failure = "outputLimit"; break
                    }
                    output.append(contentsOf: buffer.prefix(count))
                } else if count == 0 && !process.isRunning { break }
                else if count < 0 && errno != EAGAIN && errno != EINTR { failure = "readFailed"; break }
                if cancellation.isCancelled { failure = "disconnected"; break }
                if DispatchTime.now().uptimeNanoseconds >= deadline { failure = "timedOut"; break }
                if count <= 0 { usleep(10_000) }
            }
            if failure == nil && cancellation.isCancelled { failure = "disconnected" }
            if failure != nil && process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if let failure { result(nil, failure) }
            else if process.terminationStatus != 0 { result(nil, "commandFailed") }
            else if output.isEmpty { result(nil, "noData") }
            else { result(output) }
        }
    }
}
