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

    /// Hint footer at the bottom of the preview content. Subtracted from the
    /// available image area so the image never has to fight the footer for
    /// space (and thus needs no scroll).
    static let footerHeight: CGFloat = 32
    /// Inner padding around the image so it doesn't touch the rounded chrome.
    static let imagePadding: CGFloat = 12

    private func sizeToFit(item: ClipItem, model: PanelModel) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Cap at 80% of visible screen so we don't crowd menubars / Docks.
        let maxW = visible.width  * 0.8
        let maxH = visible.height * 0.8

        var size = CGSize(width: 720, height: 480)
        if item.kind == .image, let img = model.fullImage(for: item) {
            let s = img.size
            let chromeH = Self.footerHeight + Self.imagePadding * 2
            let chromeW = Self.imagePadding * 2

            // Compute how big the image area can be within the screen cap,
            // then aspect-fit the natural image into it (don't upscale).
            let availW = maxW - chromeW
            let availH = maxH - chromeH
            let scale = min(availW / s.width, availH / s.height, 1.0)
            let imgW = s.width  * scale
            let imgH = s.height * scale

            let w = max(360, imgW + chromeW)
            let h = max(260, imgH + chromeH)
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
                .frame(height: PreviewWindow.footerHeight)
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            // Long text scrolls; window is sized to the default 720×480
            // because we can't predict text rendering height cheaply.
            ScrollView {
                Text(item.content)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .image:
            // No ScrollView: the window has been sized to fit the image's
            // natural dims (clamped to 80% of screen). The image just
            // aspect-fits into the available content area so the user sees
            // the whole picture in one go.
            if let img = model.fullImage(for: item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(PreviewWindow.imagePadding)
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
