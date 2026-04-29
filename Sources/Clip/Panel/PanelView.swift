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
            KeyCatcher(
                onUp:          { model.moveSelection(by: -1) },
                onDown:        { model.moveSelection(by: 1) },
                onEnter:       { model.paste() },
                onEscape:      { model.close() },
                onPin:         { Task { await model.togglePinSelected() } },
                onDelete:      { Task { await deleteSelected() } },
                onIndex:       { n in model.selectIndex(n) },
                onFocusSearch: { searchFocused = true }
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)

            // SwiftUI cancel-action shortcut for ESC. Needed because the
            // search TextField captures first-responder, so KeyCatcher's
            // keyDown doesn't fire for ESC. cancelAction is intercepted by
            // SwiftUI at scene level regardless of focus.
            Button("") { model.close() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: PanelWindow.size.width, height: PanelWindow.size.height)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            searchFocused = true
            model.reload()
        }
    }

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

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { model.selectedID },
                set: { model.selectedID = $0 }
            )) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                    PanelRow(item: item, index: idx + 1)
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
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selectedID) { new in
                if let new {
                    withAnimation(.none) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private var footer: some View {
        Text("↑↓ 选 · ↵ 粘贴 · ⌘P 钉 · ⌘D 删 · esc 关闭")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 24)
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
/// label; preview is truncated to 120 chars (single-line).
struct PanelRow: View {
    let item: ClipItem
    let index: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if index <= 9 {
                Text("⌘\(index)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .leading)
            } else {
                Text("").frame(width: 24)
            }
            if item.pinned { Text("📌") }
            Text(preview(item.content))
                .lineLimit(1)
                .truncationMode(.tail)
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
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if one.count <= 120 { return one }
        return String(one.prefix(120)) + "…"
    }
}
