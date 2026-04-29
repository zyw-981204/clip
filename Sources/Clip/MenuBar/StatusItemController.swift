import AppKit
import KeyboardShortcuts

/// Owns the menu-bar `NSStatusItem`, builds its dropdown menu, and exposes
/// closure hooks the AppDelegate wires to actual behaviour. The icon dims
/// and switches to the "filled" SF Symbol while paused.
///
/// Marked `@MainActor` because every NSStatusItem property (button.image /
/// alphaValue / menu) must be touched on the main thread.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onOpenPanel: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenPreferences: (() -> Void)?

    var isPaused: Bool = false {
        didSet { updateIcon(); pauseItem?.title = isPaused ? "继续采集" : "暂停采集" }
    }

    private var pauseItem: NSMenuItem?
    private var openPanelItem: NSMenuItem?

    override init() {
        super.init()
        build()
        updateIcon()
        refreshHotkeyLabel()
    }

    /// NSMenuDelegate: re-read the hotkey from `KeyboardShortcuts` every time
    /// the menu is about to open, so user customisations show up immediately.
    func menuWillOpen(_ menu: NSMenu) {
        refreshHotkeyLabel()
    }

    private func build() {
        let menu = NSMenu()

        let open = BlockMenuItem(title: "打开剪贴板面板") { [weak self] in
            self?.onOpenPanel?()
        }
        menu.addItem(open)
        self.openPanelItem = open

        let pause = BlockMenuItem(title: "暂停采集") { [weak self] in
            self?.onTogglePause?()
        }
        menu.addItem(pause)
        self.pauseItem = pause

        menu.addItem(.separator())

        let prefs = BlockMenuItem(title: "偏好设置...") { [weak self] in
            self?.onOpenPreferences?()
        }
        prefs.keyEquivalent = ","
        prefs.keyEquivalentModifierMask = .command
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Re-read the current global shortcut from `KeyboardShortcuts` and update
    /// the "open panel" menu-item title so it reflects user customisations.
    /// Call this on launch and whenever the user finishes recording a new
    /// shortcut in Preferences.
    func refreshHotkeyLabel() {
        guard let item = openPanelItem else { return }
        if let s = KeyboardShortcuts.getShortcut(for: .togglePanel) {
            item.title = "打开剪贴板面板  \(s)"
        } else {
            item.title = "打开剪贴板面板（未设置热键）"
        }
    }

    private func updateIcon() {
        let name = isPaused ? "doc.on.clipboard.fill" : "doc.on.clipboard"
        statusItem.button?.image = NSImage(systemSymbolName: name,
                                           accessibilityDescription: "Clip")
        statusItem.button?.alphaValue = isPaused ? 0.5 : 1.0
    }
}

/// NSMenuItem that runs a closure when triggered. AppKit's `action` selector
/// takes a target/selector pair; we store the closure on the item itself and
/// route the selector back through `invoke()`.
private final class BlockMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func invoke() { closure() }
}
