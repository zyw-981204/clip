import AppKit
import CoreGraphics

/// Writes the chosen content to the system pasteboard with our internal-paste
/// UTI marker (so PasteboardObserver skips the self-write), closes the panel,
/// then synthesises ⌘V into the previously-frontmost app after a 50ms delay
/// so the focus has time to settle.
@MainActor
final class PasteInjector {
    /// Paste `content` into whatever app is frontmost after `close()` runs.
    /// `close` is invoked synchronously so the panel is gone before ⌘V fires.
    func paste(content: String, then close: @escaping () -> Void) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, PrivacyFilter.internalUTI], owner: nil)
        pb.setString(content, forType: .string)
        pb.setString("1", forType: PrivacyFilter.internalUTI)

        close()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.postCommandV()
        }
    }

    /// Posts a ⌘V keyDown + keyUp pair through the session event tap.
    /// Virtual key 0x09 = "V" on US layout (Apple HIToolbox kVK_ANSI_V).
    /// No-op when the app is not Accessibility-trusted; the content is still
    /// on the pasteboard so the user can ⌘V manually.
    private func postCommandV() {
        guard AccessibilityCheck.isTrusted() else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
