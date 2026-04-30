import AppKit
import CoreGraphics

/// Writes the chosen content to the system pasteboard with our internal-paste
/// UTI marker (so PasteboardObserver skips the self-write), closes the panel,
/// then synthesises ⌘V into the previously-frontmost app after a 50ms delay
/// so the focus has time to settle.
@MainActor
final class PasteInjector {
    /// Paste a text item into whatever app is frontmost after `close()`
    /// runs. `close` is invoked synchronously so the panel is gone before
    /// ⌘V fires.
    func paste(content: String, then close: @escaping () -> Void) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, PrivacyFilter.internalUTI], owner: nil)
        pb.setString(content, forType: .string)
        pb.setString("1", forType: PrivacyFilter.internalUTI)
        finalize(close: close)
    }

    /// Paste an image item. `mimeType` records the original UTI we captured
    /// so the receiver gets back what it produced ("image/png" → .png, etc.).
    /// Falls back to `.tiff` if the mime is unknown.
    func pasteImage(bytes: Data, mimeType: String, then close: @escaping () -> Void) {
        let pb = NSPasteboard.general
        let type = Self.pasteboardType(forMime: mimeType)
        pb.declareTypes([type, PrivacyFilter.internalUTI], owner: nil)
        pb.setData(bytes, forType: type)
        pb.setString("1", forType: PrivacyFilter.internalUTI)
        finalize(close: close)
    }

    private func finalize(close: @escaping () -> Void) {
        close()
        // 100ms (was 50) gives focus a bit more time to return to the
        // previously-frontmost app — some apps (Electron, terminals) need
        // the longer breathing room or the synthetic ⌘V hits a stale
        // first-responder.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.postCommandV()
        }
    }

    static func pasteboardType(forMime mime: String) -> NSPasteboard.PasteboardType {
        switch mime {
        case "image/png":       return .png
        case "image/tiff":      return .tiff
        case "application/pdf": return NSPasteboard.PasteboardType("com.adobe.pdf")
        default:                return .tiff
        }
    }

    /// Synthesise ⌘V for the previously-frontmost app.
    ///
    /// We post FOUR events — Cmd down, V down, V up, Cmd up — instead of
    /// just two V events with `.maskCommand` set. Reason: some apps
    /// (terminals like Ghostty, Electron-based apps, anything that checks
    /// system-level modifier state via NSEvent.modifierFlags rather than
    /// the per-event flags field) won't recognize the synthetic ⌘V if the
    /// Cmd key was never "pressed". The user reported pasting an image
    /// into a terminal yielded a literal "v" — that's exactly this failure
    /// mode: terminal saw the V keypress without acknowledging Cmd, fell
    /// through to plain text input.
    ///
    /// Virtual keycodes: kVK_ANSI_V = 0x09, kVK_Command (left) = 0x37.
    /// No-op if the app isn't Accessibility-trusted; the content is still
    /// on the pasteboard so the user can ⌘V manually.
    private func postCommandV() {
        guard AccessibilityCheck.isTrusted() else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let cmdKey: CGKeyCode = 0x37

        let tap: CGEventTapLocation = .cgSessionEventTap

        // Press Cmd (modifier-key keyDown synthesizes the flagsChanged
        // event the system uses to track modifier state).
        if let e = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: tap)
        }
        // Press V (with Cmd held).
        if let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: tap)
        }
        // Release V.
        if let e = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            e.flags = .maskCommand
            e.post(tap: tap)
        }
        // Release Cmd.
        if let e = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false) {
            e.flags = []
            e.post(tap: tap)
        }
    }
}
