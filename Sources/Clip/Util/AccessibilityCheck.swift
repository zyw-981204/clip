import AppKit
@preconcurrency import ApplicationServices

enum AccessibilityCheck {
    /// Returns whether this process is currently trusted for Accessibility (AX) APIs.
    /// Pass `prompt: true` to surface the system "grant access" dialog the first time.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Deep-link to System Settings → Privacy & Security → Accessibility so the
    /// user can flip the toggle for Clip.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
