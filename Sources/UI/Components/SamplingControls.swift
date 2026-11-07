import AppKit

extension Notification.Name {
    /// Posted when sampling is paused, resumed, or re-timed. The sidebar footer, Performance toolbar and Settings observe it.
    static let samplingStateDidChange = Notification.Name("Microgravity.samplingStateDidChange")
}

/// The single write path for the sampling interval and pause state. Performance's toolbar and Settings both use it,
/// so the store, the saved default and every visible control stay in step.
@MainActor
enum SamplingControls {
    /// UserDefaults key read at launch by `AppComposition`.
    nonisolated static let refreshIntervalDefaultsKey = "monitoring.refreshInterval"

    static func setInterval(_ interval: MonitoringInterval, store: any MonitoringStore) {
        store.setInterval(interval)
        UserDefaults.standard.set(interval.rawValue, forKey: refreshIntervalDefaultsKey)
        NotificationCenter.default.post(name: .samplingStateDidChange, object: nil)
    }

    static func togglePause(store: any MonitoringStore) {
        if store.isPaused {
            store.resume()
        } else {
            store.pause()
        }
        NotificationCenter.default.post(name: .samplingStateDidChange, object: nil)
    }

    /// Bare number of seconds, for example "0.5", "1", "2", "5".
    static func seconds(_ interval: MonitoringInterval) -> String {
        interval == .halfSecond ? "0.5" : String(Int(interval.rawValue))
    }

    /// Compact form for toolbar pop-ups and the sidebar footer: "0.5 s", "1 s".
    static func shortTitle(_ interval: MonitoringInterval) -> String {
        "\(seconds(interval)) s"
    }

    /// Full form for Settings: "0.5 seconds", "1 second".
    static func longTitle(_ interval: MonitoringInterval) -> String {
        switch interval {
        case .halfSecond: return "0.5 seconds"
        case .oneSecond: return "1 second"
        case .twoSeconds: return "2 seconds"
        case .fiveSeconds: return "5 seconds"
        }
    }
}
