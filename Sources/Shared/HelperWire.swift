import Foundation

struct HelperTerminationRequest: Codable {
    let version: Int
    let target: HelperTarget
    let force: Bool
}

enum HelperSampleKind: String, Codable, CaseIterable { case nettop, powermetrics }
struct HelperSampleRequest: Codable {
    let version: Int
    let kind: HelperSampleKind
}
struct HelperSampleResponse: Codable {
    let version: Int
    let kind: HelperSampleKind
    let capturedAt: Date
    let output: Data?
    let error: String?
    static let maximumOutputBytes = 4 * 1024 * 1024
}
