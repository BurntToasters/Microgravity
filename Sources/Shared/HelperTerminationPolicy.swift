import Foundation

struct HelperTarget: Codable, Equatable {
    let pid: Int32
    let seconds: Int64
    let microseconds: Int32
    let owner: UInt32
    let protected: Bool
}

enum HelperPreflightRejection: Equatable {
    case processExited
    case identityChanged
    case invalidIdentity
    case currentProcess
    case pidOne
    case protectedProcess
}

enum HelperTerminationPolicy {
    static func permits(_ observed: HelperTarget, requested: HelperTarget, clientPID: Int32, helperPID: Int32) -> Bool {
        observed.pid > 1 && observed.seconds > 0 && (0..<1_000_000).contains(observed.microseconds) &&
        observed.pid != clientPID && observed.pid != helperPID &&
        observed.pid == requested.pid && observed.seconds == requested.seconds &&
        observed.microseconds == requested.microseconds && observed.owner != 0 && !observed.protected
    }

    static func preflightRejection(observed: HelperTarget?, requested: HelperTargetIdentity,
                                   clientPID: Int32) -> HelperPreflightRejection? {
        guard let observed else { return .processExited }
        let policyTarget = HelperTarget(pid: requested.pid, seconds: requested.seconds,
                                        microseconds: requested.microseconds,
                                        owner: observed.owner, protected: observed.protected)
        let policyPermits = permits(observed, requested: policyTarget,
                                    clientPID: clientPID, helperPID: -1)
        guard observed.pid == requested.pid,
              observed.seconds == requested.seconds,
              observed.microseconds == requested.microseconds else { return .identityChanged }
        guard observed.seconds > 0, (0..<1_000_000).contains(observed.microseconds) else { return .invalidIdentity }
        guard observed.pid > 1 else { return .pidOne }
        guard observed.pid != clientPID else { return .currentProcess }
        guard observed.owner != 0, !observed.protected else { return .protectedProcess }
        return policyPermits ? nil : .protectedProcess
    }
}
