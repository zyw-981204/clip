import AppKit
import SwiftUI

/// Floating, non-activating panel that hosts the SwiftUI clip-history UI.
///
/// `.nonactivatingPanel` keeps the previously-frontmost application active so
/// that a synthesized ⌘V on close lands in the user's actual target window.
/// The window is borderless with a clear background; SwiftUI provides the
/// rounded `.thinMaterial` chrome.
final class PanelWindow: NSPanel {
    static let size = CGSize(width: 480, height: 640)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.becomesKeyOnlyIfNeeded = false
        self.hidesOnDeactivate = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
    }

    /// Borderless windows refuse key by default; override so the search field
    /// can become first responder.
    override var canBecomeKey: Bool { true }

    /// Replace the SwiftUI root. Called once during composition; subsequent
    /// state changes flow through the bound `PanelModel`.
    func setRoot<V: View>(_ view: V) {
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: Self.size)
        self.contentView = host.view
    }
}
