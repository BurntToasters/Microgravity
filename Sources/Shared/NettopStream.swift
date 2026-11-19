import Darwin
import Foundation

struct NettopDeltaEntry: Codable, Equatable, Sendable {
    let pid: Int32
    let name: String?
    let bytesIn: UInt64
    let bytesOut: UInt64
}

struct NettopDeltaFrame: Equatable, Sendable {
    let sequence: UInt64
    let capturedAt: Date
    let interval: DateInterval?
    let isBaseline: Bool
    let entries: [Int32: NettopDeltaEntry]
}

enum NettopStreamHealth: String, Codable, Equatable, Sendable {
    case warmingUp
    case healthy
    case unavailable
}

struct NettopStreamSnapshot: Equatable, Sendable {
    let health: NettopStreamHealth
    let capturedAt: Date
    let interval: DateInterval?
    let latestSequence: UInt64
    let totalsByPID: [Int32: NettopDeltaEntry]
    let error: String?
}

/// Stateful incremental line parser for streaming `nettop -n -P -x -t external -d -L 0 -s 1 -J bytes_in,bytes_out` output.
struct NettopDeltaFrameParser: Sendable {
    static let maximumFrameBytes = 4 * 1024 * 1024

    private(set) var sequence: UInt64 = 0
    private var inFrame = false
    private var hasSeenBaseline = false
    private var lastFrameDate: Date?
    private var currentEntries: [Int32: NettopDeltaEntry] = [:]
    private var currentAmbiguousPIDs = Set<Int32>()
    private var currentFrameBytes = 0

    init(initialSequence: UInt64 = 0) {
        self.sequence = initialSequence
    }

    static func isHeaderLine(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.hasSuffix(",") ? String(trimmed.dropLast()) : trimmed
        let fields = normalized.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return fields == ["", "bytes_in", "bytes_out"]
    }

    static func parseProcessLine(_ rawLine: String) -> NettopDeltaEntry? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHeaderLine(trimmed) else { return nil }
        if trimmed.hasSuffix(",") {
            trimmed.removeLast()
        }
        // Parse from the right so commas inside process names do not break fixed trailing columns.
        guard let lastComma = trimmed.lastIndex(of: ",") else { return nil }
        let bytesOutString = trimmed[trimmed.index(after: lastComma)...].trimmingCharacters(in: .whitespaces)
        guard let bytesOut = UInt64(bytesOutString) else { return nil }

        let beforeOut = trimmed[..<lastComma]
        guard let secondLastComma = beforeOut.lastIndex(of: ",") else { return nil }
        let bytesInString = beforeOut[beforeOut.index(after: secondLastComma)...].trimmingCharacters(in: .whitespaces)
        guard let bytesIn = UInt64(bytesInString) else { return nil }

        let identifierField = String(beforeOut[..<secondLastComma]).trimmingCharacters(in: .whitespaces)
        guard let dotIndex = identifierField.lastIndex(of: ".") else { return nil }
        let pidPart = identifierField[identifierField.index(after: dotIndex)...]
        guard let pid = Int32(pidPart), pid > 0 else { return nil }

        let namePart = String(identifierField[..<dotIndex]).trimmingCharacters(in: .whitespaces)
        return NettopDeltaEntry(pid: pid, name: namePart.isEmpty ? nil : namePart, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    mutating func consumeLine(_ rawLine: String, at timestamp: Date = Date()) -> NettopDeltaFrame? {
        if Self.isHeaderLine(rawLine) {
            let emitted = commitPendingFrame(at: timestamp)
            inFrame = true
            currentEntries.removeAll(keepingCapacity: true)
            currentAmbiguousPIDs.removeAll(keepingCapacity: true)
            currentFrameBytes = rawLine.utf8.count
            return emitted
        }

        guard inFrame else { return nil }
        currentFrameBytes += rawLine.utf8.count + 1
        guard currentFrameBytes <= Self.maximumFrameBytes else {
            inFrame = false
            currentEntries.removeAll(keepingCapacity: true)
            currentAmbiguousPIDs.removeAll(keepingCapacity: true)
            return nil
        }

        guard let entry = Self.parseProcessLine(rawLine) else { return nil }
        if currentAmbiguousPIDs.contains(entry.pid) { return nil }
        if currentEntries[entry.pid] != nil {
            currentEntries.removeValue(forKey: entry.pid)
            currentAmbiguousPIDs.insert(entry.pid)
            return nil
        }
        currentEntries[entry.pid] = entry
        return nil
    }

    mutating func commitPendingFrame(at timestamp: Date = Date()) -> NettopDeltaFrame? {
        guard inFrame else { return nil }
        defer {
            inFrame = false
            currentEntries.removeAll(keepingCapacity: true)
            currentAmbiguousPIDs.removeAll(keepingCapacity: true)
            currentFrameBytes = 0
        }

        let isBaseline = !hasSeenBaseline
        hasSeenBaseline = true
        let interval: DateInterval?
        if let previous = lastFrameDate, timestamp > previous, !isBaseline {
            interval = DateInterval(start: previous, end: timestamp)
        } else {
            interval = nil
        }
        lastFrameDate = timestamp
        sequence &+= 1
        return NettopDeltaFrame(sequence: sequence, capturedAt: timestamp, interval: interval,
                                isBaseline: isBaseline, entries: currentEntries)
    }

    /// Convenience helper for synchronously parsing a multi-frame capture in tests.
    static func parseFrames(from text: String, frameTimestamps: [Date] = []) -> [NettopDeltaFrame] {
        var parser = NettopDeltaFrameParser()
        var frames: [NettopDeltaFrame] = []
        var frameIndex = 0
        let fallbackStart = Date(timeIntervalSince1970: 1_000)

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let timestamp = frameIndex < frameTimestamps.count
                ? frameTimestamps[frameIndex]
                : fallbackStart.addingTimeInterval(Double(frameIndex))
            if let completed = parser.consumeLine(line, at: timestamp) {
                frames.append(completed)
                frameIndex += 1
            }
        }

        let finalTimestamp = frameIndex < frameTimestamps.count
            ? frameTimestamps[frameIndex]
            : fallbackStart.addingTimeInterval(Double(frameIndex))
        if let finalFrame = parser.commitPendingFrame(at: finalTimestamp) {
            frames.append(finalFrame)
        }
        return frames
    }
}

/// Manages a lazy, auto-stopping persistent `/usr/bin/nettop -t external -d` stream.
final class NettopStreamService: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "run.rosie.microgravity.nettop-stream")
    private let command: SamplingRunner.Command
    private let idleTimeoutSeconds: TimeInterval
    private let staleTimeoutSeconds: TimeInterval
    private let maximumBufferedFrames = 120

    private var isRunning = false
    private var child: SampledChild?
    private var readSource: DispatchSourceRead?
    private var idleWorkItem: DispatchWorkItem?
    private var flushWorkItem: DispatchWorkItem?
    private var outputFD: Int32 = -1
    private var lineBuffer = Data()
    private var parser = NettopDeltaFrameParser()
    private var frames: [NettopDeltaFrame] = []
    private var highestSequence: UInt64 = 0
    private var lastClientPollAt: Date?
    private var lastFrameReceivedAt: Date?
    private var startedAt: Date?
    private var lastError: String?

    init(command: SamplingRunner.Command = SamplingRunner.fixedCommand(.nettopStream),
         idleTimeoutSeconds: TimeInterval = 15.0,
         staleTimeoutSeconds: TimeInterval = 5.0) {
        self.command = command
        self.idleTimeoutSeconds = max(2.0, idleTimeoutSeconds)
        self.staleTimeoutSeconds = max(2.0, staleTimeoutSeconds)
    }

    deinit {
        stop()
    }

    func latestSnapshot(since sequence: UInt64? = nil, now: Date = Date()) -> NettopStreamSnapshot {
        lock.lock()
        lastClientPollAt = now
        let shouldStart = !isRunning
        if shouldStart {
            startLocked(now: now)
        }
        rescheduleIdleTimerLocked()

        let deltaFrames = frames.filter { !$0.isBaseline }
        let latestSequence = deltaFrames.last?.sequence ?? parser.sequence
        let lastReceived = lastFrameReceivedAt
        let activeError = lastError
        let running = isRunning
        let started = startedAt

        let selected: [NettopDeltaFrame]
        if let sequence {
            let unseen = deltaFrames.filter { $0.sequence > sequence }
            if !unseen.isEmpty {
                selected = unseen
            } else if let latest = deltaFrames.last,
                      now.timeIntervalSince(latest.capturedAt) <= staleTimeoutSeconds {
                selected = [latest]
            } else {
                selected = []
            }
        } else if let latest = deltaFrames.last,
                  now.timeIntervalSince(latest.capturedAt) <= staleTimeoutSeconds {
            selected = [latest]
        } else {
            selected = []
        }
        lock.unlock()

        if !selected.isEmpty {
            let combined = Self.combine(frames: selected)
            return NettopStreamSnapshot(health: .healthy,
                                        capturedAt: selected.last?.capturedAt ?? now,
                                        interval: combined.interval,
                                        latestSequence: selected.last?.sequence ?? latestSequence,
                                        totalsByPID: combined.entries,
                                        error: nil)
        }

        if let started, running,
           now.timeIntervalSince(lastReceived ?? started) <= staleTimeoutSeconds {
            return NettopStreamSnapshot(health: .warmingUp, capturedAt: now, interval: nil,
                                        latestSequence: latestSequence, totalsByPID: [:], error: nil)
        }

        if running, let referenceDate = lastReceived ?? started,
           now.timeIntervalSince(referenceDate) > staleTimeoutSeconds {
            restartIfStale(now: now)
        }

        return NettopStreamSnapshot(health: .unavailable, capturedAt: now, interval: nil,
                                    latestSequence: latestSequence, totalsByPID: [:],
                                    error: activeError ?? "streamUnavailable")
    }

    func stop() {
        lock.lock()
        let runningChild = stopLocked(resetFrames: false)
        lock.unlock()
        Self.terminateAndReap(runningChild)
    }

    private func restartIfStale(now: Date) {
        lock.lock()
        let runningChild = stopLocked(resetFrames: false)
        lastError = "streamStalled"
        startLocked(now: now)
        rescheduleIdleTimerLocked()
        lock.unlock()
        Self.terminateAndReap(runningChild)
    }

    private static func terminateAndReap(_ child: SampledChild?) {
        guard let child else { return }
        child.kill()
        child.waitForExit()
    }

    private func startLocked(now: Date) {
        guard !isRunning else { return }

        guard let transport = Self.openOutputChannel() else {
            lastError = "ptyFailed"
            return
        }

        let launchedChild = SampledChild.launch(command, output: transport.slaveFD)
        if transport.slaveFD >= 0 { close(transport.slaveFD) }

        guard let launchedChild else {
            if transport.masterFD >= 0 { close(transport.masterFD) }
            lastError = "spawnFailed"
            return
        }

        isRunning = true
        child = launchedChild
        outputFD = transport.masterFD
        startedAt = now
        lastFrameReceivedAt = nil
        lastError = nil
        lineBuffer.removeAll(keepingCapacity: false)
        parser = NettopDeltaFrameParser(initialSequence: highestSequence)

        let fd = transport.masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable(fd: fd)
        }
        source.setCancelHandler {
            if fd >= 0 { close(fd) }
        }
        readSource = source
        source.resume()
    }

    private func stopLocked(resetFrames: Bool) -> SampledChild? {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        flushWorkItem?.cancel()
        flushWorkItem = nil

        if let source = readSource {
            readSource = nil
            source.cancel()
        } else if outputFD >= 0 {
            close(outputFD)
        }
        outputFD = -1

        let runningChild = child
        child = nil

        lineBuffer.removeAll(keepingCapacity: false)
        isRunning = false
        if resetFrames {
            frames.removeAll(keepingCapacity: false)
        }
        return runningChild
    }

    private func rescheduleIdleTimerLocked() {
        idleWorkItem?.cancel()
        let timeout = idleTimeoutSeconds
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            var expiredChild: SampledChild?
            let now = Date()
            if let lastPoll = self.lastClientPollAt, now.timeIntervalSince(lastPoll) >= timeout {
                expiredChild = self.stopLocked(resetFrames: false)
            }
            self.lock.unlock()
            Self.terminateAndReap(expiredChild)
        }
        idleWorkItem = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func handleReadable(fd: Int32) {
        var temp = [UInt8](repeating: 0, count: 16_384)
        var readAny = false
        while true {
            let count = Darwin.read(fd, &temp, temp.count)
            if count > 0 {
                readAny = true
                lock.lock()
                lineBuffer.append(contentsOf: temp[0..<count])
                if lineBuffer.count > NettopDeltaFrameParser.maximumFrameBytes {
                    lineBuffer.removeAll(keepingCapacity: false)
                }
                lock.unlock()
                continue
            }
            if count == 0 {
                lock.lock()
                flushCompletedLinesLocked(now: Date())
                commitPendingFrameLocked(now: Date())
                var endedChild: SampledChild?
                if isRunning && outputFD == fd {
                    lastError = "streamEnded"
                    endedChild = stopLocked(resetFrames: false)
                }
                lock.unlock()
                Self.terminateAndReap(endedChild)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            lock.lock()
            var failedChild: SampledChild?
            if isRunning && outputFD == fd {
                lastError = "readFailed"
                failedChild = stopLocked(resetFrames: false)
            }
            lock.unlock()
            Self.terminateAndReap(failedChild)
            return
        }

        if readAny {
            lock.lock()
            flushCompletedLinesLocked(now: Date())
            scheduleFrameSettleLocked()
            lock.unlock()
        }
    }

    private func flushCompletedLinesLocked(now: Date) {
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                if let frame = parser.consumeLine(line, at: now) {
                    recordFrameLocked(frame)
                }
            }
        }
    }

    private func scheduleFrameSettleLocked() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.isRunning, self.lineBuffer.isEmpty else { return }
            self.commitPendingFrameLocked(now: Date())
        }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func commitPendingFrameLocked(now: Date) {
        if let frame = parser.commitPendingFrame(at: now) {
            recordFrameLocked(frame)
        }
    }

    private func recordFrameLocked(_ frame: NettopDeltaFrame) {
        highestSequence = max(highestSequence, frame.sequence)
        lastFrameReceivedAt = frame.capturedAt
        frames.append(frame)
        if frames.count > maximumBufferedFrames {
            frames.removeFirst(frames.count - maximumBufferedFrames)
        }
    }

    private static func combine(frames: [NettopDeltaFrame]) -> (interval: DateInterval?, entries: [Int32: NettopDeltaEntry]) {
        guard let first = frames.first else { return (nil, [:]) }
        if frames.count == 1 {
            return (first.interval, first.entries)
        }
        var totals: [Int32: NettopDeltaEntry] = [:]
        for frame in frames {
            for (pid, entry) in frame.entries {
                if let existing = totals[pid] {
                    totals[pid] = NettopDeltaEntry(
                        pid: pid,
                        name: existing.name ?? entry.name,
                        bytesIn: existing.bytesIn &+ entry.bytesIn,
                        bytesOut: existing.bytesOut &+ entry.bytesOut
                    )
                } else {
                    totals[pid] = entry
                }
            }
        }
        let interval: DateInterval?
        if let start = frames.compactMap(\.interval?.start).min(),
           let end = frames.compactMap(\.interval?.end).max(),
           end > start {
            interval = DateInterval(start: start, end: end)
        } else {
            interval = frames.last?.interval
        }
        return (interval, totals)
    }

    private struct OutputChannel {
        let masterFD: Int32
        let slaveFD: Int32
    }

    private static func openOutputChannel() -> OutputChannel? {
        // nettop block-buffers stdout on pipes when -L 0 runs continuously; a PTY gives immediate 1s flushes.
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        if masterFD >= 0 {
            _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
            if grantpt(masterFD) == 0,
               unlockpt(masterFD) == 0,
               let cName = ptsname(masterFD) {
                let slaveFD = open(cName, O_RDWR | O_NOCTTY | O_CLOEXEC)
                if slaveFD >= 0 {
                    var attrs = termios()
                    if tcgetattr(slaveFD, &attrs) == 0 {
                        attrs.c_lflag &= ~tcflag_t(ECHO | ICANON)
                        attrs.c_oflag &= ~tcflag_t(OPOST)
                        _ = tcsetattr(slaveFD, TCSANOW, &attrs)
                    }
                    let flags = fcntl(masterFD, F_GETFL, 0)
                    if flags >= 0 {
                        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
                    }
                    return OutputChannel(masterFD: masterFD, slaveFD: slaveFD)
                }
            }
            close(masterFD)
        }

        // Fall back to a pipe if PTY allocation fails in restricted environments.
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fds[0], F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)
        }
        return OutputChannel(masterFD: fds[0], slaveFD: fds[1])
    }
}
