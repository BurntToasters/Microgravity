import AppKit

/// Presents an `NSAlert` as a sheet attached to a window, so confirmations stay with their window.
///
/// Use `present(on:...)` in place of `runModal()`. The window-less fallback runs modally, which
/// only happens when the calling page has no window to attach to.
@MainActor
enum SheetAlert {
    /// Shows the alert and returns the response for the clicked button (first button = `.alertFirstButtonReturn`).
    /// - Parameters:
    ///   - window: The window to attach the sheet to. Nil falls back to `runModal()`.
    ///   - defaultButtonIdentifier: Accessibility identifier set on the first (default) button, for UI tests.
    ///   - destructiveButtonIndex: Index of the button that performs a destructive action. It is marked with
    ///     `hasDestructiveAction`, so AppKit renders it as destructive. Nil marks no button.
    @discardableResult
    static func present(on window: NSWindow?,
                        style: NSAlert.Style = .warning,
                        messageText: String,
                        informativeText: String? = nil,
                        buttons: [String] = [String(localized: "OK")],
                        defaultButtonIdentifier: String? = nil,
                        destructiveButtonIndex: Int? = nil) async -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = messageText
        if let informativeText { alert.informativeText = informativeText }
        for title in buttons.isEmpty ? [String(localized: "OK")] : buttons {
            alert.addButton(withTitle: title)
        }
        if let defaultButtonIdentifier, let defaultButton = alert.buttons.first {
            defaultButton.setAccessibilityIdentifier(defaultButtonIdentifier)
        }
        if let destructiveButtonIndex, alert.buttons.indices.contains(destructiveButtonIndex) {
            alert.buttons[destructiveButtonIndex].hasDestructiveAction = true
        }
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
