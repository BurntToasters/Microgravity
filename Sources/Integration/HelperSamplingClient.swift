import Foundation
import ServiceManagement

/// Manages a reusable authenticated XPC connection to `MicrogravityHelper`.
actor HelperSamplingClient {
    /// Failure reason reported when the privileged helper is not registered, enabled, or verifiable.
    static let unavailableError = "helperUnavailable"

    /// While the daemon was last seen enabled, its status is re-read at most this often (seconds of uptime).
    static let statusRecheckInterval: TimeInterval = 5

    /// Requirement verified by the latest `prepareRefresh()`; nil when the helper was unavailable then.
    private var requirement: String?
    private var cachedConnection: NSXPCConnection?
    private var cachedRequirement: String?
    private var cachedConnectionID: UUID?
    private var pendingReplies: [UUID: CachedXPCReply] = [:]

    private let daemonIsEnabled: @Sendable () -> Bool
    private let signingRequirement: @Sendable () -> String?
    private let uptime: @Sendable () -> TimeInterval
    /// Set once a signing requirement has been verified; a failed lookup leaves it nil so it is retried.
    private var verifiedRequirement: String?
    private var lastStatusWasEnabled = false
    private var lastStatusCheckUptime: TimeInterval = 0
    /// Set by any connection invalidation, so the next `prepareRefresh()` re-reads the daemon status.
    private var statusRecheckRequired = false

    /// Production defaults: the daemon's `SMAppService` status, the app's own signing requirement, and system uptime.
    init(daemonIsEnabled: @escaping @Sendable () -> Bool = {
             SMAppService.daemon(plistName: helperMachService + ".plist").status == .enabled
         },
         signingRequirement: @escaping @Sendable () -> String? = {
             SigningIdentity.requirement(for: helperSigningIdentifier)
         },
         uptime: @escaping @Sendable () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.daemonIsEnabled = daemonIsEnabled
        self.signingRequirement = signingRequirement
        self.uptime = uptime
    }

    /// Checks daemon registration and signing once per refresh, not once per sample kind.
    /// Status is cheap to re-read only so often: while enabled it is re-checked at most every
    /// `statusRecheckInterval` and after a connection invalidation; while not enabled, on every call.
    func prepareRefresh() async -> Bool {
        requirement = nil
        guard daemonStatusIsEnabled(), let verified = verifiedSigningRequirement() else {
            invalidateConnection(reason: Self.unavailableError)
            return false
        }
        requirement = verified
        return true
    }

    private func daemonStatusIsEnabled() -> Bool {
        let now = uptime()
        if lastStatusWasEnabled, !statusRecheckRequired, now >= lastStatusCheckUptime,
           now - lastStatusCheckUptime < Self.statusRecheckInterval {
            return true
        }
        let enabled = daemonIsEnabled()
        lastStatusWasEnabled = enabled
        lastStatusCheckUptime = now
        statusRecheckRequired = false
        return enabled
    }

    private func verifiedSigningRequirement() -> String? {
        if let verifiedRequirement { return verifiedRequirement }
        guard let fresh = signingRequirement() else { return nil }
        verifiedRequirement = fresh
        return fresh
    }

    /// Must follow `prepareRefresh()` in the same refresh; otherwise reports `helperUnavailable`.
    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        func failure(_ reason: String) -> HelperSampleResponse {
            HelperSampleResponse(version: helperProtocolVersion, kind: kind, capturedAt: Date(), output: nil, error: reason)
        }
        guard let codeRequirement = requirement else { return failure(Self.unavailableError) }
        guard let request = try? JSONEncoder().encode(
            HelperSampleRequest(version: helperProtocolVersion, kind: kind)
        ) else { return failure("invalidRequest") }

        let (connection, connectionID) = activeConnection(for: codeRequirement)
        let callID = UUID()
        let timeout: TimeInterval = kind == .processMetrics ? 10 : 25

        let response = await withCheckedContinuation { continuation in
            let token = CachedXPCReply(continuation, timeout: timeout, timeoutValue: failure("timedOut")) { [weak self] in
                await self?.finishPendingCall(callID: callID)
            }
            pendingReplies[callID] = token

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                token.finish(failure("connectionFailed"))
            }) as? HelperProtocol else {
                token.finish(failure("protocolUnavailable"))
                return
            }

            proxy.sample(request) { data in
                token.finish(Self.decodeResponse(data, kind: kind) ?? failure("incompatibleResponse"))
            }
            token.armTimeout()
        }

        if let error = response.error, Self.shouldInvalidateConnection(afterError: error), cachedConnectionID == connectionID {
            invalidateConnection(reason: error)
        }
        return response
    }

    private func activeConnection(for requirement: String) -> (NSXPCConnection, UUID) {
        if let cachedConnection, let cachedConnectionID, cachedRequirement == requirement {
            return (cachedConnection, cachedConnectionID)
        }
        invalidateConnection(reason: "connectionReplaced")

        let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
        let connectionID = UUID()
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { await self?.handleConnectionDrop(connectionID: connectionID, reason: "connectionInterrupted") }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.handleConnectionDrop(connectionID: connectionID, reason: "connectionInvalidated") }
        }
        connection.resume()
        cachedConnection = connection
        cachedRequirement = requirement
        cachedConnectionID = connectionID
        return (connection, connectionID)
    }

    private func handleConnectionDrop(connectionID: UUID, reason: String) {
        guard cachedConnectionID == connectionID else { return }
        invalidateConnection(reason: reason)
    }

    /// Internal so tests can simulate a connection drop; production reaches it from the XPC handlers and error paths.
    func invalidateConnection(reason: String) {
        statusRecheckRequired = true
        let staleConnection = cachedConnection
        cachedConnection = nil
        cachedRequirement = nil
        cachedConnectionID = nil
        let outstanding = Array(pendingReplies.values)
        pendingReplies.removeAll()
        for reply in outstanding {
            reply.failIfPending(reason: reason)
        }
        staleConnection?.invalidate()
    }

    private func finishPendingCall(callID: UUID) {
        pendingReplies.removeValue(forKey: callID)
    }

    private static func shouldInvalidateConnection(afterError code: String) -> Bool {
        switch code {
        case "timedOut", "disconnected", "connectionFailed", "connectionInterrupted",
             "connectionInvalidated", "incompatibleVersion", "incompatibleResponse", "protocolUnavailable":
            return true
        default:
            return false
        }
    }

    private static func decodeResponse(_ data: Data, kind: HelperSampleKind) -> HelperSampleResponse? {
        // JSON carries base64-encoded output; bound it before decoding too.
        guard data.count <= (HelperSampleResponse.maximumOutputBytes * 4 / 3 + 4096),
              let response = try? JSONDecoder().decode(HelperSampleResponse.self, from: data),
              response.kind == kind,
              (response.output?.count ?? 0) <= HelperSampleResponse.maximumOutputBytes else { return nil }
        if response.version != helperProtocolVersion {
            return HelperSampleResponse(version: response.version, kind: kind,
                                        capturedAt: response.capturedAt,
                                        output: nil,
                                        error: response.error ?? "incompatibleVersion")
        }
        return response
    }
}

private final class CachedXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperSampleResponse, Never>?
    private let timeout: TimeInterval
    private let timeoutValue: HelperSampleResponse
    private let onComplete: @Sendable () async -> Void

    init(_ continuation: CheckedContinuation<HelperSampleResponse, Never>,
         timeout: TimeInterval,
         timeoutValue: HelperSampleResponse,
         onComplete: @escaping @Sendable () async -> Void) {
        self.continuation = continuation
        self.timeout = timeout
        self.timeoutValue = timeoutValue
        self.onComplete = onComplete
    }

    func armTimeout() {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(timeoutValue)
        }
    }

    func failIfPending(reason: String) {
        finish(HelperSampleResponse(version: helperProtocolVersion, kind: timeoutValue.kind,
                                    capturedAt: Date(), output: nil, error: reason))
    }

    func finish(_ value: HelperSampleResponse) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        guard let saved else { return }
        saved.resume(returning: value)
        Task { await onComplete() }
    }
}
