import AppKit
import SwiftUI

/// SwiftUI bridge to a first-responder `NSView` that intercepts `keyDown`
/// events for the panel. SwiftUI's `List` keyboard-nav doesn't work
/// reliably inside a `.nonactivatingPanel`, and `.onKeyPress` (macOS 14+)
/// only fires when its host view has focus — which the search field steals.
/// This view sits behind the UI, becomes first responder when the panel
/// opens, and dispatches recognised shortcuts to the supplied closures.
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
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
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

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Defer so the window has finished installing; otherwise
        // makeFirstResponder fails silently.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let h = handlers else { return super.keyDown(with: event) }

        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        // ⌘1 – ⌘9 take precedence over plain digits.
        if cmd, let digit = Int(chars), (1...9).contains(digit) {
            h.onIndex(digit); return
        }

        if cmd {
            switch chars.lowercased() {
            case "p": h.onPin(); return
            case "d": h.onDelete(); return
            case "f": h.onFocusSearch(); return
            default: break
            }
        }

        switch event.keyCode {
        case 126: h.onUp()      // up arrow
        case 125: h.onDown()    // down arrow
        case 36, 76: h.onEnter()        // return / numpad-enter
        case 53: h.onEscape()           // escape
        case 51, 117: h.onDelete()      // backspace / forward-delete
        default:
            super.keyDown(with: event)
        }
    }
}
