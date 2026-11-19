import Foundation

/// Turns IOReport energy deltas into watts for one component.
///
/// Fast counters (`GPU Energy`, nJ) change on every sample, so `joules / tickLength` is correct.
/// Slow counters (`CPU Energy`, DRAM, ANE, cluster channels, mJ) refresh only about every 2 s, so a tick
/// can carry 0 J and the next tick two ticks' worth. Dividing each tick by its length alternates between
/// 0 W and 2x. A slow counter therefore holds its last watts between refreshes and divides a refresh by the
/// measured refresh period. A component that stays at 0 J for `holdLimit` reports 0 W.
struct EnergyRateTracker {
    static let holdLimit: TimeInterval = 5
    private static let gapWindow = 8

    private var held: Double?
    private var lastEnergyEnd: Date?
    private var idleSince: Date?
    private var zeroSinceEnergy = false
    private var primed = false
    private var recentGaps: [TimeInterval] = []

    init() {}

    /// Feeds one tick's energy delta (joules over `interval`) and returns the component's watts.
    mutating func update(_ joules: Double, interval: DateInterval) -> Double? {
        if joules <= 0 {
            zeroSinceEnergy = true
            let idleStart = idleSince ?? interval.start
            idleSince = idleStart
            if interval.end.timeIntervalSince(lastEnergyEnd ?? idleStart) > Self.holdLimit {
                held = 0
                recentGaps = []
                primed = false
            }
            return held
        }

        let previousEnd = lastEnergyEnd
        let wasZero = zeroSinceEnergy
        let wasPrimed = primed
        lastEnergyEnd = interval.end
        zeroSinceEnergy = false
        primed = true
        idleSince = nil

        // The first sighting only anchors the window: its delta covers time before we started watching.
        guard wasPrimed, let previousEnd else { return held }

        if !wasZero {
            // The counter refreshed on the previous tick too: the tick length is the refresh period.
            recentGaps = []
            let duration = interval.duration
            if duration > 0 {
                held = joules / duration
            }
        } else {
            // The counter skipped at least one tick: divide by the measured refresh period.
            let gap = interval.end.timeIntervalSince(previousEnd)
            if gap > 0 {
                recentGaps.append(gap)
                if recentGaps.count > Self.gapWindow {
                    recentGaps.removeFirst(recentGaps.count - Self.gapWindow)
                }
                let meanGap = recentGaps.reduce(0, +) / Double(recentGaps.count)
                held = joules / meanGap
            }
        }
        return held
    }
}

/// The IOReport channel role that feeds one energy component.
enum EnergyChannelRole: Hashable, Sendable {
    case cpu
    case gpu
    case ane
    case dram
    /// Per-cluster CPU channels (`ECPU`, `PCPU1`, `MCPU1`). Used only when no `cpu` channel exists.
    case cpuCluster

    /// Maps an "Energy Model" channel name to its role. Names without a role (per-core, detail and
    /// per-die-cluster channels) return nil so that no energy is counted twice.
    static func role(forChannelName name: String) -> EnergyChannelRole? {
        if name.hasSuffix("CPU Energy") { return .cpu }
        if name.hasSuffix("GPU Energy") { return .gpu }
        if name.hasPrefix("ANE") { return .ane }
        if name.hasPrefix("DRAM") { return .dram }
        if isClusterCPUName(name) { return .cpuCluster }
        return nil
    }

    /// Matches `^[EPM]CPU[0-9]*$`.
    private static func isClusterCPUName(_ name: String) -> Bool {
        guard let first = name.first, "EPM".contains(first) else { return false }
        let rest = name.dropFirst()
        guard rest.hasPrefix("CPU") else { return false }
        return rest.dropFirst(3).allSatisfy { ("0"..."9").contains($0) }
    }
}
