import SwiftUI

/// Top-level SwiftUI view hosted inside `PanelWindow`. Layout:
///   ┌──────────────────────┐
///   │ search field         │ 40 pt
///   ├──────────────────────┤
///   │ scrollable list      │ flex
///   ├──────────────────────┤
///   │ keyboard-hint footer │ 24 pt
///   └──────────────────────┘
/// The `KeyCatcher` overlays the whole stack so it captures keyboard events
/// regardless of which subview the cursor is over. The search field handles
/// its own typing; KeyCatcher only intercepts modifier shortcuts and the
/// arrow / return / escape / backspace keys (which the text field doesn't
/// need for caret movement when single-line and unselected).
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                list
                Divider()
                footer
            }

            // ESC backstop. PanelWindow's local key monitor is the primary
            // path; this catches the case where the monitor isn't installed
            // yet (e.g. the very first keyDown before showAtCursor returns).
            Button("") { model.close() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            // ⌘F focuses the search field. Handled here (rather than in the
            // window's monitor) because @FocusState can only be flipped from
            // inside the SwiftUI view tree.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: PanelWindow.size.width, height: contentHeight)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if let item = model.previewItem {
                previewOverlay(item: item)
            }
        }
        .onAppear {
            // Do NOT auto-focus the search field. Focusing the field would
            // route ↑↓ / digit keypresses to the field editor first, making
            // the panel feel unresponsive. The user can click the field (or
            // press ⌘F) to enter filter mode.
            model.reload()
            resizePanel()
        }
        .onChange(of: model.pageItems.count) { _ in resizePanel() }
        .onChange(of: model.currentPage)     { _ in resizePanel() }
    }

    /// Computed height of the rendered SwiftUI content. Drives both the
    /// SwiftUI `.frame(height:)` and the NSPanel's `setFrame` so the two
    /// stay in lockstep — no empty band below the last row when the
    /// current page has fewer than `pageSize` items.
    private var contentHeight: CGFloat {
        let chrome: CGFloat = PanelView.searchBarHeight
                            + 1                                  // top divider
                            + 1                                  // bottom divider
                            + PanelView.footerHeight
        let rows = model.items.isEmpty
            ? PanelView.emptyStateHeight
            : CGFloat(model.pageItems.count) * PanelRow.height
        return chrome + rows
    }

    /// Push the computed height into the NSPanel, anchoring its top edge so
    /// the panel "grows / shrinks downward" rather than jumping vertically.
    private func resizePanel() {
        guard let panel = NSApp.windows.compactMap({ $0 as? PanelWindow }).first
        else { return }
        let target = contentHeight
        var f = panel.frame
        let dy = f.height - target
        guard abs(dy) > 0.5 else { return }
        f.size.height = target
        f.origin.y += dy           // keep top edge in place
        panel.setFrame(f, display: true, animate: false)
    }

    static let searchBarHeight: CGFloat = 40
    static let footerHeight: CGFloat = 36
    static let emptyStateHeight: CGFloat = 200

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索剪贴板", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onChange(of: model.query) { _ in model.reload() }
                .onSubmit { model.paste() }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder
    private var list: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            // No ScrollViewReader / scrollTo here: we paginate at 10 rows so
            // every visible row already fits inside the panel — calling
            // proxy.scrollTo on each selectedID change is pure overhead and
            // makes ↑↓ navigation feel laggy.
            List(selection: Binding(
                get: { model.selectedID },
                set: { model.selectedID = $0 }
            )) {
                ForEach(Array(model.pageItems.enumerated()), id: \.element.id) { idx, item in
                    PanelRow(item: item, index: idx + 1, model: model)
                        .id(item.id)
                        .tag(item.id)
                        .listRowBackground(
                            item.id == model.selectedID
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.selectedID = item.id
                            model.paste()
                        }
                        .onTapGesture {
                            model.selectedID = item.id
                        }
                        .contextMenu {
                            Button(item.pinned ? "取消置顶" : "置顶") {
                                Task { await model.togglePin(item: item) }
                            }
                            Button("复制原文") {
                                model.copyToPasteboard(item)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                Task { @MainActor in
                                    await model.delete(item: item) {
                                        await PanelDeleteConfirm.confirm(
                                            window: NSApp.keyWindow,
                                            content: item.content
                                        )
                                    }
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty
                  ? "doc.on.clipboard"
                  : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "暂无剪贴板记录" : "无匹配结果")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("复制任意文字即可开始记录")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("↑↓ 选 · ←→ 翻页 · ↵ 粘贴 · ⎵ 预览 · ⌘1–9 直接粘")
            HStack(spacing: 6) {
                Text("⌘F 搜 · ⌘P 钉 · ⌘D 删 · esc 关闭")
                if !model.items.isEmpty {
                    Text("·")
                    Text("第 \(model.currentPage + 1) / \(model.pageCount) 页")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }

    /// Quick-Look-style preview overlay. Click anywhere or press ⎵ / esc to
    /// dismiss (the keypress is wired through `PanelWindow.handleKeyDown`).
    @ViewBuilder
    private func previewOverlay(item: ClipItem) -> some View {
        VStack(spacing: 0) {
            switch item.kind {
            case .text:
                ScrollView {
                    Text(item.content)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
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
                    VStack {
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

            Divider()
            Text("⎵ / esc 关闭预览")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.previewItem = nil }
    }

    /// Dispatches delete with the pinned-confirmation hook wired to NSAlert.
    private func deleteSelected() async {
        await model.deleteSelected {
            await PanelDeleteConfirm.confirm(
                window: NSApp.keyWindow,
                content: model.selectedItem()?.content ?? ""
            )
        }
    }
}

/// Single list row. Pinned rows show a 📌 prefix; right-aligned source-app
/// label. Text rows show a one-line preview (truncated to 120 chars). Image
/// rows show a 32×32 inline thumbnail + size / mime metadata.
///
/// All rows are forced to a uniform 40pt — the 32×32 thumbnail in image rows
/// is the floor, and matching text rows to the same height keeps mixed-type
/// pages visually consistent (otherwise paging from images-heavy → text-only
/// would cause a height mismatch).
struct PanelRow: View {
    static let height: CGFloat = 40

    let item: ClipItem
    let index: Int
    let model: PanelModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if index <= 9 {
                Text("⌘\(index)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .leading)
            } else {
                Text("").frame(width: 24)
            }
            if item.pinned { Text("📌") }

            switch item.kind {
            case .text:
                Text(preview(item.content))
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .image:
                imageBody
            }

            Spacer(minLength: 12)
            if let app = item.sourceAppName, !app.isEmpty {
                Text(app)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if item.truncated {
                Text("(截断)").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height,
               maxHeight: Self.height, alignment: .leading)
    }

    @ViewBuilder
    private var imageBody: some View {
        HStack(spacing: 8) {
            if let img = model.thumbnail(for: item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
            }
            Text(imageLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Short metadata label for image rows: "图片 · 230 KB · png".
    private var imageLabel: String {
        let kb = max(1, item.byteSize / 1024)
        let suffix = (item.mimeType ?? "").split(separator: "/").last.map(String.init) ?? "image"
        return "图片 · \(kb) KB · \(suffix)"
    }

    private func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if one.count <= 120 { return one }
        return String(one.prefix(120)) + "…"
    }
}
