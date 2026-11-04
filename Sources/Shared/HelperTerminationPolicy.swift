import Foundation

struct HelperTarget: Codable, Equatable {
    let pid: Int32
    let seconds: Int64
    let microseconds: Int32
    let owner: UInt32
    let protected: Bool
}

enum HelperTerminationPolicy {
    static func permits(_ observed: HelperTarget, requested: HelperTarget, clientPID: Int32, helperPID: Int32) -> Bool {
        observed.pid > 1 && observed.seconds > 0 && (0..<1_000_000).contains(observed.microseconds) &&
        observed.pid != clientPID && observed.pid != helperPID &&
        observed.pid == requested.pid && observed.seconds == requested.seconds &&
        observed.microseconds == requested.microseconds && observed.owner != 0 && !observed.protected
    }
}
