import Foundation

/// Resumes a checked continuation exactly once. The first of the reply, an XPC
/// error, interruption, invalidation, or the timeout wins; later calls are no-ops.
/// Finishing also invalidates the connection so the helper is not left half-open.
final class XPCSingleReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private let connection: NSXPCConnection
    private let timeout: TimeInterval
    private let timeoutValue: Value

    init(_ continuation: CheckedContinuation<Value, Never>, connection: NSXPCConnection,
         timeout: TimeInterval, timeoutValue: Value) {
        self.continuation = continuation
        self.connection = connection
        self.timeout = timeout
        self.timeoutValue = timeoutValue
    }

    /// Starts the timeout clock. Call after the request is sent so a hung helper
    /// cannot leak the continuation.
    func armTimeout() {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(timeoutValue)
        }
    }

    func finish(_ value: Value) {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        guard let saved else { return }
        connection.invalidate()
        saved.resume(returning: value)
    }
}
