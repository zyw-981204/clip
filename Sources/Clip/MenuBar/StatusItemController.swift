import AppKit

/// Owns the menu-bar `NSStatusItem`, builds its dropdown menu, and exposes
/// closure hooks the AppDelegate wires to actual behaviour. The icon dims
/// and switches to the "filled" SF Symbol while paused.
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onOpenPanel: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenPreferences: (() -> Void)?

    var isPaused: Bool = false {
        didSet { updateIcon(); pauseItem?.title = isPaused ? "继续采集" : "暂停采集" }
    }

    private var pauseItem: NSMenuItem?

    init() {
        build()
        updateIcon()
    }

    private func build() {
        let menu = NSMenu()

        menu.addItem(BlockMenuItem(title: "打开剪贴板面板  ⌃⌥⌘V") { [weak self] in
            self?.onOpenPanel?()
        })

        let pause = BlockMenuItem(title: "暂停采集") { [weak self] in
            self?.onTogglePause?()
        }
        menu.addItem(pause)
        self.pauseItem = pause

        menu.addItem(.separator())

        menu.addItem(BlockMenuItem(title: "偏好设置...  ⌘,") { [weak self] in
            self?.onOpenPreferences?()
        })

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出  ⌘Q",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "")
        menu.addItem(quit)

        statusItem.menu = menu
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
