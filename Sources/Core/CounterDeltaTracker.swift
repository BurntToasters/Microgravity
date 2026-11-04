import Foundation

enum CounterDeltaResult: Equatable {
    case baseline
    case delta(value: UInt64, elapsed: TimeInterval)
    case counterReset
    case sleepGap
    case invalidTimestamp
}

/// Tracks independent monotonic counters without converting missing intervals to zero.
struct CounterDeltaTracker<Key: Hashable> {
    private struct Baseline {
        let value: UInt64
        let timestamp: Date
    }

    private var baselines: [Key: Baseline] = [:]
    let maximumInterval: TimeInterval

    init(maximumInterval: TimeInterval = 30) {
        self.maximumInterval = maximumInterval > 0 ? maximumInterval : 30
    }

    mutating func update(_ value: UInt64, for key: Key, at timestamp: Date) -> CounterDeltaResult {
        guard let previous = baselines[key] else {
            baselines[key] = Baseline(value: value, timestamp: timestamp)
            return .baseline
        }

        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return .invalidTimestamp }
        guard elapsed <= maximumInterval else {
            baselines[key] = Baseline(value: value, timestamp: timestamp)
            return .sleepGap
        }
        guard value >= previous.value else {
            baselines[key] = Baseline(value: value, timestamp: timestamp)
            return .counterReset
        }

        baselines[key] = Baseline(value: value, timestamp: timestamp)
        return .delta(value: value - previous.value, elapsed: elapsed)
    }

    mutating func remove(_ key: Key) {
        baselines.removeValue(forKey: key)
    }

    mutating func retain(_ keys: Set<Key>) {
        baselines = baselines.filter { keys.contains($0.key) }
    }

    mutating func removeAll() {
        baselines.removeAll(keepingCapacity: true)
    }
}

extension CounterDeltaResult {
    var unavailableReason: MetricUnavailableReason? {
        switch self {
        case .baseline: return .warmingUp
        case .delta: return nil
        case .counterReset: return .counterReset
        case .sleepGap: return .sleepGap
        case .invalidTimestamp: return .collectionFailed
        }
    }

    func reading(unit: MetricUnit, timestamp: Date,
                 valueTransform: (UInt64, TimeInterval) -> Double) -> MetricReading {
        switch self {
        case .baseline:
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .warmingUp)
        case let .delta(value, elapsed):
            return MetricReading(value: valueTransform(value, elapsed), unit: unit, timestamp: timestamp)
        case .counterReset:
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .counterReset)
        case .sleepGap:
            return MetricReading(unavailable: unit, timestamp: timestamp, reason: .sleepGap)
        case .invalidTimestamp:
            return MetricReading(unavailable: unit, timestamp: timestamp,
                                 reason: .collectionFailed, detail: "Non-increasing collection timestamp")
        }
    }
}
