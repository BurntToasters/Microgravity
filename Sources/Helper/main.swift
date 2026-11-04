import Foundation

final class Service: NSObject, HelperProtocol {
    let cancellation = SamplingCancellation()
    let clientPID: Int32
    init(clientPID: Int32) { self.clientPID = clientPID }
    func sample(_ data: Data, reply: @escaping (Data) -> Void) {
        guard data.count <= 4096, let request = try? JSONDecoder().decode(HelperSampleRequest.self, from: data) else { reply(Data()); return }
        SamplingRunner.shared.sample(request, cancellation: cancellation) { response in
            reply((try? JSONEncoder().encode(response)) ?? Data())
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
