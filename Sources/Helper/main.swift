import Foundation

/// NSXPC passes this block as the response endpoint for an asynchronous exported
/// method. SamplingRunner invokes it once on its serial queue; it carries no helper
/// state, and XPC transports the reply to the caller. Keep this unchecked bridge at
/// the Objective-C/XPC boundary rather than erasing Sendable on SamplingRunner's API.
private final class XPCSampleReply: @unchecked Sendable {
    private let handler: (Data) -> Void

    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }

    func send(_ data: Data) { handler(data) }
}

final class Service: NSObject, HelperProtocol {
    let cancellation = SamplingCancellation()
    let clientPID: Int32
    init(clientPID: Int32) { self.clientPID = clientPID }
    func sample(_ data: Data, reply: @escaping (Data) -> Void) {
        guard data.count <= 4096, let request = try? JSONDecoder().decode(HelperSampleRequest.self, from: data) else { reply(Data()); return }
        let xpcReply = XPCSampleReply(reply)
        SamplingRunner.shared.sample(request, cancellation: cancellation) { response in
            xpcReply.send((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func terminate(_ request: Data, authorization: Data, reply: @escaping (String) -> Void) {
        reply(TerminationService.perform(request, authorization: authorization, clientPID: clientPID))
    }
    func capabilities(_ reply: @escaping (Int, [String]) -> Void) {
        let tools: [(String, String)] = [("nettop", "/usr/bin/nettop"), ("powermetrics", "/usr/bin/powermetrics")]
        reply(helperProtocolVersion, tools.filter { FileManager.default.isExecutableFile(atPath: $0.1) }.map { $0.0 })
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = SigningIdentity.requirement(for: appSigningIdentifier) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        // Defense in depth only: connection.processIdentifier is a bare PID that the OS
        // can reuse after the client exits. It is used solely to refuse self-termination.
        // The code-signing requirement above is the real gate on who may connect. Do not
        // widen what clientPID authorizes; if it must, capture the audit token or the
        // PID plus start time at connect time instead.
        let service = Service(clientPID: connection.processIdentifier)
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancellation.cancel() }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: helperMachService)
let delegate = Listener()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
