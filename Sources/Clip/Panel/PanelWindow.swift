import AppKit
import SwiftUI

/// Floating, non-activating panel that hosts the SwiftUI clip-history UI.
///
/// `.nonactivatingPanel` keeps the previously-frontmost application active so
/// that a synthesized ⌘V on close lands in the user's actual target window.
/// The window is borderless with a clear background; SwiftUI provides the
/// rounded `.thinMaterial` chrome.
final class PanelWindow: NSPanel {
    /// Initial panel dimensions. After SwiftUI renders, `PanelView`
    /// re-computes height from actual `pageItems.count × PanelRow.height`
    /// + chrome and resizes via `setFrame`, so this is just the "first
    /// frame" target. 480 wide, 480 tall covers a full 10-row page (10 × 40
    /// = 400 rows + 78 chrome ≈ 478pt) without an immediate resize jump.
    static let size = CGSize(width: 480, height: 480)

    /// Closures invoked by the local key-down monitor. Set once after the
    /// panel + model are wired up in AppDelegate. The monitor runs on every
    /// keyDown delivered to this window — irrespective of which subview
    /// (search field, list, etc.) currently has first-responder — so this
    /// is the reliable place to handle shortcuts.
    struct KeyHandlers {
        let onUp: () -> Void
        let onDown: () -> Void
        let onEnter: () -> Void
        let onEscape: () -> Void
        let onPin: () -> Void
        let onDelete: () -> Void
        let onIndex: (Int) -> Void
        let onFocusSearch: () -> Void
        let onPrevPage: () -> Void
        let onNextPage: () -> Void
        let onPreview: () -> Void
        /// ⌥1 / ⌥2 / ⌥3 → 全部 / 文字 / 图片. 1-based.
        let onSwitchTab: (Int) -> Void
        /// ⌘N → mark the selected item as not-syncing (sync exclude toggle).
        var onExclude: () -> Void = {}
    }

    var keyHandlers: KeyHandlers?
    private var keyMonitor: Any?

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

    private var activateObserver: NSObjectProtocol?

    /// Begin observing app-switches so the panel closes if the user activates
    /// any other application (Cmd-Tab, Dock click, Spotlight, etc.). We
    /// install the observer in `showAtCursor` and remove it in `close` so we
    /// don't fire while the panel is hidden.
    private func startWatchingAppSwitches() {
        guard activateObserver == nil else { return }
        let mineBundleID = Bundle.main.bundleIdentifier
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != mineBundleID
            else { return }
            // Notification queue is `.main`, so we're already on the main
            // thread; assumeIsolated lets us call the MainActor-isolated
            // `close()` synchronously without a Task hop.
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopWatchingAppSwitches() {
        if let obs = activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activateObserver = nil
        }
    }

    override func close() {
        stopWatchingAppSwitches()
        removeKeyMonitor()
        super.close()
    }

    /// Backstop for ESC: NSResponder forwards unhandled `cancelOperation:`
    /// up the chain. The local key monitor below is the primary path; this
    /// is a safety net.
    override func cancelOperation(_ sender: Any?) {
        self.close()
    }

    // MARK: - Key event monitor

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// Returns nil to consume the event, the event itself to pass through.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let h = keyHandlers else { return event }
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        // ⌘1 – ⌘9 → jump-paste Nth row.
        if cmd, let digit = Int(chars), (1...9).contains(digit) {
            h.onIndex(digit); return nil
        }

        // ⌥1 / ⌥2 / ⌥3 → switch content filter tab (全部 / 文字 / 图片).
        // `charactersIgnoringModifiers` returns the bare digit even with
        // Option held (e.g. ⌥1 → "1", not "¡").
        let opt = event.modifierFlags.contains(.option)
        if opt && !cmd, let digit = Int(chars), (1...3).contains(digit) {
            h.onSwitchTab(digit); return nil
        }

        if cmd {
            switch chars.lowercased() {
            case "p": h.onPin(); return nil
            case "d": h.onDelete(); return nil
            case "n": h.onExclude(); return nil
            // ⌘F is handled by a SwiftUI keyboardShortcut button in PanelView
            // (it needs @FocusState access to flip the search field's focus).
            // Letting the event through allows SwiftUI's shortcut to catch it.
            default: break
            }
        }

        switch event.keyCode {
        case 36, 76:                     // return / numpad-enter
            h.onEnter(); return nil
        case 53:                         // escape
            h.onEscape(); return nil
        case 126:                        // up arrow
            h.onUp(); return nil
        case 125:                        // down arrow
            h.onDown(); return nil
        case 123, 124:                   // left / right arrow → page flip
            // If the search field is focused with text in it, let arrow keys
            // move the caret instead of flipping pages.
            if let editor = self.firstResponder as? NSText, !editor.string.isEmpty {
                return event
            }
            if event.keyCode == 123 { h.onPrevPage() } else { h.onNextPage() }
            return nil
        case 51, 117:                    // backspace / forward-delete
            // If the search field is focused with text in it, let backspace
            // edit the query rather than deleting a clipboard item.
            if let editor = self.firstResponder as? NSText, !editor.string.isEmpty {
                return event
            }
            h.onDelete(); return nil
        case 49:                         // space → Quick-Look-style preview
            // If the search field has focus, let space type into it.
            if self.firstResponder is NSText {
                return event
            }
            h.onPreview(); return nil
        default:
            // Letters / digits without ⌘ — forward to focused field (search).
            return event
        }
    }

    /// Show the panel anchored near the mouse cursor:
    /// the panel's top-left corner sits at (cursor.x + 12, cursor.y - 12),
    /// then we clamp to the cursor's current screen `visibleFrame` so the
    /// panel never spills off-screen on multi-monitor setups.
    func showAtCursor() {
        positionNearCursor()
        self.makeKeyAndOrderFront(nil)
        // AppKit's default initial-first-responder logic auto-focuses the
        // first text field on key, which steers ⎵ / arrow keys into the
        // search field's editor instead of our local key monitor. Clear it
        // so the panel's window-level monitor sees keypresses unmodified.
        // ⌘F still re-focuses the field on demand.
        self.makeFirstResponder(nil)
        startWatchingAppSwitches()
        installKeyMonitor()
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
