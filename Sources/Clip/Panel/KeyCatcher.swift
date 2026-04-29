import AppKit
import SwiftUI

/// SwiftUI bridge that installs an `NSEvent.addLocalMonitorForEvents` on
/// the host window. The previous first-responder approach was unreliable
/// because the SwiftUI search field grabs focus and the responder chain
/// never reaches us. A local key-down monitor is invoked BEFORE the
/// responder chain, so it works regardless of which subview has focus.
///
/// The monitor returns `nil` to consume an event or returns the event to
/// pass through (e.g. arrows still drive SwiftUI List nav, typing keys
/// still reach the search field).
struct KeyCatcher: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onEnter: () -> Void
    var onEscape: () -> Void
    var onPin: () -> Void          // ⌘P
    var onDelete: () -> Void       // ⌘D or ⌫
    var onIndex: (Int) -> Void     // ⌘1 … ⌘9 → 1…9
    var onFocusSearch: () -> Void  // ⌘F

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.handlers = handlers()
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.handlers = handlers()
    }

    private func handlers() -> KeyCatcherView.Handlers {
        .init(onUp: onUp, onDown: onDown, onEnter: onEnter, onEscape: onEscape,
              onPin: onPin, onDelete: onDelete, onIndex: onIndex,
              onFocusSearch: onFocusSearch)
    }
}

final class KeyCatcherView: NSView {
    struct Handlers {
        let onUp: () -> Void
        let onDown: () -> Void
        let onEnter: () -> Void
        let onEscape: () -> Void
        let onPin: () -> Void
        let onDelete: () -> Void
        let onIndex: (Int) -> Void
        let onFocusSearch: () -> Void
    }

    var handlers: Handlers?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    deinit { removeMonitor() }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, event.window === w else { return event }
            return self.handle(event)
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Returns nil to consume the event, or the event itself to pass through.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let h = handlers else { return event }
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        // ⌘1 – ⌘9 take precedence over plain digits.
        if cmd, let digit = Int(chars), (1...9).contains(digit) {
            h.onIndex(digit); return nil
        }

        if cmd {
            switch chars.lowercased() {
            case "p": h.onPin(); return nil
            case "d": h.onDelete(); return nil
            case "f": h.onFocusSearch(); return nil
            default: break
            }
        }

        switch event.keyCode {
        case 36, 76:                      // return / numpad-enter
            h.onEnter(); return nil
        case 53:                          // escape
            h.onEscape(); return nil
        case 51, 117:                     // backspace / forward-delete
            // Only treat as "delete history item" when search field is NOT
            // the first responder; otherwise let the user backspace search text.
            if let editor = window?.firstResponder as? NSText, editor.string.isEmpty == false {
                return event
            }
            if window?.firstResponder is NSTextView { return event }
            h.onDelete(); return nil
        default:
            // Arrow keys, alphanumerics for the search field, etc.
            return event
        }
    }
}
