import Foundation

@MainActor
enum HelperHandshake {
    static func check(requirement: String) async -> IntegrationAvailability {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            let completion = HandshakeCompletion(continuation, connection)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.interruptionHandler = { completion.finish(.failed("Helper connection interrupted.")) }
            connection.invalidationHandler = { completion.finish(.failed("Helper connection invalidated.")) }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion.finish(.failed("Helper connection failed.")) }) as? HelperProtocol else {
                completion.finish(.failed("Helper protocol unavailable.")); return
            }
            proxy.capabilities { version, _ in
                completion.finish(version == helperProtocolVersion ? .available : .failed("Helper protocol version is incompatible; remove and reinstall the helper."))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { completion.finish(.failed("Helper connection timed out.")) }
        }
    }
}
private final class HandshakeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IntegrationAvailability, Never>?
    private let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<IntegrationAvailability, Never>, _ connection: NSXPCConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ value: IntegrationAvailability) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        guard let saved else { return }
        connection.invalidate()
        saved.resume(returning: value)
    }
}
