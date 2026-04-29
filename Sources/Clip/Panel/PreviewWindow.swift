import AppKit
import SwiftUI

/// Standalone, screen-centered Quick-Look-style preview. Sits OUTSIDE the
/// `PanelWindow` so the preview isn't constrained by the panel's small
/// 480-wide footprint — full images get rendered at a comfortable size,
/// and text rows can scroll without fighting the row list for vertical
/// space.
///
/// The window is a borderless `NSPanel` (so it floats over arbitrary apps),
/// becomes key while visible (so its local key monitor sees ⎵ / esc), and
/// orders itself out + invokes a dismiss callback when the user closes it.
final class PreviewWindow: NSPanel {
    static let shared = PreviewWindow()

    private var keyMonitor: Any?
    private var onDismiss: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: 720, height: 480)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .modalPanel              // sits above the PanelWindow
        self.becomesKeyOnlyIfNeeded = false
        self.hidesOnDeactivate = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                   .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// Show the preview for `item`. `onDismiss` is invoked when the user
    /// closes the preview (so the caller can reset `model.previewItem`).
    func show(item: ClipItem, model: PanelModel, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let host = NSHostingController(
            rootView: PreviewContent(item: item, model: model)
        )
        self.contentViewController = host
        sizeToFit(item: item, model: model)
        self.center()
        installKeyMonitor()
        self.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeKeyMonitor()
        self.orderOut(nil)
        let cb = onDismiss
        onDismiss = nil
        cb?()
    }

    private func sizeToFit(item: ClipItem, model: PanelModel) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = visible.width  * 0.7
        let maxH = visible.height * 0.7

        var size = CGSize(width: 720, height: 480)
        if item.kind == .image, let img = model.fullImage(for: item) {
            let s = img.size
            // Aspect-fit; never upscale beyond 1×.
            let scale = min(maxW / s.width, maxH / s.height, 1.0)
            // Min 320 so tiny clipboard icons don't show in a thumbnail-sized
            // window; chrome (footer hint + padding) ≈ 40pt extra height.
            let w = max(320, s.width  * scale)
            let h = max(220, s.height * scale + 40)
            size = CGSize(width: w, height: h)
        }
        self.setContentSize(size)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            // ⎵ (49) / esc (53) close the preview.
            if event.keyCode == 49 || event.keyCode == 53 {
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

/// SwiftUI body of the preview. Click-anywhere also dismisses (the closure
/// is wired via the host's onDismissCallback environment so the window can
/// orderOut itself); for now the window's key monitor handles dismissal.
private struct PreviewContent: View {
    let item: ClipItem
    let model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Text("⎵ / esc 关闭预览")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.content)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .image:
            if let img = model.fullImage(for: item) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("无法加载预览")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
