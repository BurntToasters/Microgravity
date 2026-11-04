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
            let completion = SampleCompletion(continuation, connection, kind)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.interruptionHandler = { completion.fail("connectionInterrupted") }
            connection.invalidationHandler = { completion.fail("connectionInvalidated") }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in completion.fail("connectionFailed") }) as? HelperProtocol else {
                completion.fail("protocolUnavailable"); return
            }
            proxy.sample(request) { completion.accept($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { completion.fail("timedOut") }
        }
    }
}
private final class SampleCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperSampleResponse, Never>?
    private let connection: NSXPCConnection
    private let kind: HelperSampleKind
    init(_ continuation: CheckedContinuation<HelperSampleResponse, Never>, _ connection: NSXPCConnection, _ kind: HelperSampleKind) {
        self.continuation = continuation; self.connection = connection; self.kind = kind
    }
    func accept(_ data: Data) {
        // JSON carries base64-encoded output; bound it before decoding too.
        guard data.count <= (HelperSampleResponse.maximumOutputBytes * 4 / 3 + 4096),
              let response = try? JSONDecoder().decode(HelperSampleResponse.self, from: data),
              response.version == helperProtocolVersion, response.kind == kind,
              (response.output?.count ?? 0) <= HelperSampleResponse.maximumOutputBytes else {
            fail("incompatibleResponse"); return
        }
        finish(response)
    }
    func fail(_ reason: String) {
        finish(HelperSampleResponse(version: helperProtocolVersion, kind: kind, capturedAt: Date(), output: nil, error: reason))
    }
    private func finish(_ response: HelperSampleResponse) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        guard let saved else { return }
        connection.invalidate()
        saved.resume(returning: response)
    }
}
