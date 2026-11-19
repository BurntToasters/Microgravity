import Foundation

struct HelperTerminationRequest: Codable, Sendable {
    let version: Int
    let target: HelperTarget
    let force: Bool
}

enum HelperSampleKind: String, Codable, CaseIterable, Sendable {
    case nettop
    case powermetrics
    case nettopStream
    case processMetrics
}

struct HelperSampleRequest: Codable, Sendable {
    let version: Int
    let kind: HelperSampleKind
    let sinceSequence: UInt64?

    init(version: Int, kind: HelperSampleKind, sinceSequence: UInt64? = nil) {
        self.version = version
        self.kind = kind
        self.sinceSequence = sinceSequence
    }
}

struct HelperNettopDeltaEntry: Codable, Equatable, Sendable {
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
}

struct HelperNettopStreamPayload: Codable, Equatable, Sendable {
    let health: NettopStreamHealth
    let intervalStart: Date?
    let intervalEnd: Date?
    let sequence: UInt64
    let entries: [HelperNettopDeltaEntry]
    let detail: String?
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
