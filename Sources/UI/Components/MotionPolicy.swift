import AppKit

/// Motion preference for UI-driven animation. Animated changes run with zero duration when Reduce Motion is on.
@MainActor
enum MotionPolicy {
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `changes` in an animation group that is instant under Reduce Motion and 0.2 s otherwise.
    static func animate(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = prefersReducedMotion ? 0 : 0.2
            changes()
        }
    }
}
