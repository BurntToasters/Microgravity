import Foundation
import ServiceManagement

actor HelperSamplingClient {
    func sample(_ kind: HelperSampleKind) async -> HelperSampleResponse {
        func failure(_ reason: String) -> HelperSampleResponse {
            HelperSampleResponse(version: helperProtocolVersion, kind: kind, capturedAt: Date(), output: nil, error: reason)
        }
        guard SMAppService.daemon(plistName: helperMachService + ".plist").status == .enabled,
              let requirement = SigningIdentity.requirement(for: helperSigningIdentifier) else { return failure("helperUnavailable") }
        guard let request = try? JSONEncoder().encode(HelperSampleRequest(version: helperProtocolVersion, kind: kind)) else { return failure("invalidRequest") }
        return await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: helperMachService, options: .privileged)
            let reply = XPCSingleReply(continuation, connection: connection, timeout: 25,
                                       timeoutValue: failure("timedOut"))
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.interruptionHandler = { reply.finish(failure("connectionInterrupted")) }
            connection.invalidationHandler = { reply.finish(failure("connectionInvalidated")) }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(failure("connectionFailed")) }) as? HelperProtocol else {
                reply.finish(failure("protocolUnavailable")); return
            }
            proxy.sample(request) { data in
                reply.finish(Self.decodeResponse(data, kind: kind) ?? failure("incompatibleResponse"))
            }
            reply.armTimeout()
        }
    }

    private static func decodeResponse(_ data: Data, kind: HelperSampleKind) -> HelperSampleResponse? {
        // JSON carries base64-encoded output; bound it before decoding too.
        guard data.count <= (HelperSampleResponse.maximumOutputBytes * 4 / 3 + 4096),
              let response = try? JSONDecoder().decode(HelperSampleResponse.self, from: data),
              response.version == helperProtocolVersion, response.kind == kind,
              (response.output?.count ?? 0) <= HelperSampleResponse.maximumOutputBytes else { return nil }
        return response
    }
}
