import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePanel = Self(
        "togglePanel",
        default: .init(.v, modifiers: [.control, .option, .command])
    )
}

/// Wraps KeyboardShortcuts registration so the rest of the app stays agnostic
/// of the underlying SPM dependency. `onToggle` is invoked on the main thread
/// each time the user presses the configured shortcut.
final class HotkeyManager {
    var onToggle: (() -> Void)?

    /// Register the global key handler. Must be called once after the app
    /// finishes launching. KeyboardShortcuts persists user customisations in
    /// `UserDefaults` under `KeyboardShortcuts_togglePanel`.
    func install() {
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.onToggle?()
        }
    }
}
