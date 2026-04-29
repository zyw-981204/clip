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

    /// Show the panel anchored near the mouse cursor:
    /// the panel's top-left corner sits at (cursor.x + 12, cursor.y - 12),
    /// then we clamp to the cursor's current screen `visibleFrame` so the
    /// panel never spills off-screen on multi-monitor setups.
    func showAtCursor() {
        positionNearCursor()
        self.makeKeyAndOrderFront(nil)
    }

    private func positionNearCursor() {
        // NSEvent.mouseLocation is in screen coordinates with a bottom-left origin.
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(cursor, $0.frame, false)
        }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else {
            self.setFrameOrigin(.zero); return
        }

        // We want the panel's top-left corner at (cursor.x + 12, cursor.y - 12).
        // AppKit `setFrameOrigin` sets the bottom-left corner, so subtract the
        // panel height to convert top-left → bottom-left.
        let topLeftX = cursor.x + 12
        let topLeftY = cursor.y - 12
        var originX = topLeftX
        var originY = topLeftY - Self.size.height

        // Clamp horizontally.
        if originX + Self.size.width > frame.maxX {
            originX = frame.maxX - Self.size.width
        }
        if originX < frame.minX { originX = frame.minX }

        // Clamp vertically.
        if originY < frame.minY { originY = frame.minY }
        if originY + Self.size.height > frame.maxY {
            originY = frame.maxY - Self.size.height
        }

        self.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
