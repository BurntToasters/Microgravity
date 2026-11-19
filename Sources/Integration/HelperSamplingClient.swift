import Foundation
import ServiceManagement

/// Manages a reusable authenticated XPC connection to `MicrogravityHelper`.
actor HelperSamplingClient {
    /// Failure reason reported when the privileged helper is not registered, enabled, or verifiable.
    static let unavailableError = "helperUnavailable"

    /// Requirement verified by the latest `prepareRefresh()`; nil when the helper was unavailable then.
    private var requirement: String?
    private var cachedConnection: NSXPCConnection?
    private var cachedRequirement: String?
    private var cachedConnectionID: UUID?
    private var pendingReplies: [UUID: CachedXPCReply] = [:]

    nonisolated var supportsProtocolV2: Bool { true }

    /// Checks daemon registration and signing once per refresh, not once per sample kind.
    func prepareRefresh() async -> Bool {
        requirement = nil
        guard SMAppService.daemon(plistName: helperMachService + ".plist").status == .enabled,
              let verified = SigningIdentity.requirement(for: helperSigningIdentifier) else {
            invalidateConnection(reason: Self.unavailableError)
            return false
        }
        requirement = verified
        return true
    }

    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        await sample(kind, sinceSequence: nil)
    }

    /// Must follow `prepareRefresh()` in the same refresh; otherwise reports `helperUnavailable`.
    func sample(_ kind: HelperSampleKind, sinceSequence: UInt64?) async -> HelperSampleResponse {
        func failure(_ reason: String) -> HelperSampleResponse {
            HelperSampleResponse(version: helperProtocolVersion, kind: kind, capturedAt: Date(), output: nil, error: reason)
        }
        guard let codeRequirement = requirement else { return failure(Self.unavailableError) }
        guard let request = try? JSONEncoder().encode(
            HelperSampleRequest(version: helperProtocolVersion, kind: kind, sinceSequence: sinceSequence)
        ) else { return failure("invalidRequest") }

        let (connection, connectionID) = activeConnection(for: codeRequirement)
        let callID = UUID()
        let timeout: TimeInterval = (kind == .nettopStream || kind == .processMetrics) ? 10 : 25

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

    private func invalidateConnection(reason: String) {
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
