import AppKit
import Foundation
import os.log
@preconcurrency import ApplicationServices

private let axLogger = Logger(subsystem: "com.zyw.clip", category: "Accessibility")

enum AccessibilityCheck {
    /// Returns whether this process is currently trusted for Accessibility (AX) APIs.
    /// Pass `prompt: true` to surface the system "grant access" dialog the first time.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let opts: CFDictionary = [key: prompt] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(opts)
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        axLogger.info("isTrusted(prompt: \(prompt, privacy: .public)) -> \(result, privacy: .public) [pid=\(pid) bundle=\(bundlePath, privacy: .public)]")
        return result
    }

    /// Deep-link to System Settings → Privacy & Security → Accessibility so the
    /// user can flip the toggle for Clip.
    static func openSystemSettings() {
        axLogger.info("openSystemSettings called")
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
