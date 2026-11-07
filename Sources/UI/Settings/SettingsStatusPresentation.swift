import AppKit

/// Maps integration states to status-dot tones (`StatusTone`, defined in Components/StatusDotView.swift).
/// Text stays in the controller; this is the color decision only.
enum IntegrationStatusTone {
    static func helper(_ status: IntegrationAvailability) -> StatusTone {
        switch status {
        case .available: .positive
        case .notConfigured: .neutral
        case .requiresApproval: .attention
        case .unavailable: .neutral
        case .failed: .failure
        }
    }

    static func loginItem(_ status: LoginItemAvailability) -> StatusTone {
        switch status {
        case .enabled: .positive
        case .disabled: .neutral
        case .requiresApproval: .attention
        case .unavailable: .neutral
        case .failed: .failure
        }
    }

    static func updates(_ status: UpdateAvailability) -> StatusTone {
        switch status {
        case .current: .positive
        case .idle, .checking: .neutral
        case .updateAvailable: .attention
        case .unavailable: .neutral
        case .failed: .failure
        }
    }
}
