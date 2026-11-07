import Foundation

@MainActor
enum HelperHandshake {
    static func check(requirement: String) async -> IntegrationAvailability {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            let completion = XPCSingleReply(continuation, connection: connection, timeout: 5,
                                            timeoutValue: .failed("Helper connection timed out."))
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
            completion.armTimeout()
        }
    }
}

