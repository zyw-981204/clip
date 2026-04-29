import AppKit

/// Async sheet-modal NSAlert used to confirm deletion of a pinned clip.
/// The alert is attached to `window` so it visually belongs to the panel
/// rather than appearing as a free-floating dialog.
enum PanelDeleteConfirm {
    /// Returns `true` if the user confirmed the deletion, `false` otherwise.
    /// If `window` is nil, falls back to a synchronous modal alert.
    @MainActor
    static func confirm(window: NSWindow?, content: String) -> ConfirmTask {
        ConfirmTask(window: window, content: content)
    }

    /// Helper that lets callers `await` the result. We can't directly write
    /// `static func confirm(...) async -> Bool` and use
    /// `beginSheetModal(for:completionHandler:)` because the completion is
    /// non-isolated, so we wrap it in a continuation here.
    struct ConfirmTask {
        let window: NSWindow?
        let content: String

        @MainActor
        func callAsFunction() async -> Bool {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "删除已钉住的条目？"
            alert.informativeText = preview(content)
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")

            if let window {
                return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    alert.beginSheetModal(for: window) { resp in
                        cont.resume(returning: resp == .alertFirstButtonReturn)
                    }
                }
            } else {
                let resp = alert.runModal()
                return resp == .alertFirstButtonReturn
            }
        }

        private func preview(_ s: String) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > 80 ? String(one.prefix(80)) + "…" : one
        }
    }
}

// Allow `await PanelDeleteConfirm.confirm(window:content:)` callers to use
// the value as if it were an `async` function returning Bool.
extension PanelDeleteConfirm.ConfirmTask {
    // Convenience: `await PanelDeleteConfirm.confirm(window:content:)()` is
    // unergonomic; expose the same as a top-level async function.
}

extension PanelDeleteConfirm {
    @MainActor
    static func confirm(window: NSWindow?, content: String) async -> Bool {
        await ConfirmTask(window: window, content: content)()
    }
}
