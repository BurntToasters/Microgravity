import Foundation

enum HelperSampleKind: String, Codable, CaseIterable, Sendable {
    case powermetrics
    case processMetrics
}

struct HelperSampleRequest: Codable, Sendable {
    let version: Int
    let kind: HelperSampleKind
}

struct HelperProcessMetricEntry: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: Int64
    let startMicroseconds: Int32
    let cpuTotalNanoseconds: UInt64?
    let memoryBytes: UInt64?
    let diskReadBytes: UInt64?
    let diskWriteBytes: UInt64?
    let threadCount: Int32?
    let executablePath: String?
}

struct HelperProcessMetricsPayload: Codable, Equatable, Sendable {
    let entries: [HelperProcessMetricEntry]
}
struct HelperSampleResponse: Codable, Sendable {
    let version: Int
    let kind: HelperSampleKind
    let capturedAt: Date
    let output: Data?
    let error: String?
    static let maximumOutputBytes = 4 * 1024 * 1024
}
