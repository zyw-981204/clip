import AppKit
import Foundation
import SwiftUI

/// Drives `PanelView`. Owns the search query, the current item list, and the
/// selected row id. All published mutations happen on the main actor.
///
/// Search is debounced: each `reload()` schedules a 100 ms `Task.sleep` and
/// runs `HistoryStore.search` only if not cancelled. Successive `reload()`
/// calls cancel the previous task so a fast typer never sees stale results.
@MainActor
final class PanelModel: ObservableObject {
    /// Items shown per page. Matches the ⌘1–9 jump-paste shortcut so the
    /// digit on each visible row is always its actual hotkey.
    static let pageSize: Int = 9

    @Published var query: String = ""
    @Published private(set) var items: [ClipItem] = []
    @Published var selectedID: Int64?
    /// 0-based current page index. Reset to 0 on every reload.
    @Published var currentPage: Int = 0
    /// Set to `true` by `close()`; `PanelView` (or its host) observes and
    /// closes the panel window. Reset to `false` each time the panel is shown.
    @Published var shouldClose: Bool = false

    /// Number of pages required to display all loaded items. Always ≥ 1 so
    /// the footer can render "第 1 / 1 页" even when empty.
    var pageCount: Int {
        max(1, (items.count + Self.pageSize - 1) / Self.pageSize)
    }

    /// The slice of `items` visible on the current page (≤ `pageSize` rows).
    var pageItems: [ClipItem] {
        guard !items.isEmpty else { return [] }
        let start = currentPage * Self.pageSize
        guard start < items.count else { return [] }
        let end = min(start + Self.pageSize, items.count)
        return Array(items[start..<end])
    }

    private let store: HistoryStore
    private let onPasteCallback: (ClipItem) -> Void
    private var searchTask: Task<Void, Never>?

    init(store: HistoryStore, onPaste: @escaping (ClipItem) -> Void) {
        self.store = store
        self.onPasteCallback = onPaste
    }

    /// Trigger a debounced search/listRecent load. Safe to call repeatedly.
    /// Always resets `currentPage` to 0 — content has changed, so the freshest
    /// rows on page 0 are the right place to start.
    func reload() {
        searchTask?.cancel()
        let q = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            guard let self else { return }
            let result: [ClipItem]
            do {
                result = try q.trimmingCharacters(in: .whitespaces).isEmpty
                    ? self.store.listRecent(limit: 50)
                    : self.store.search(query: q, limit: 50)
            } catch {
                result = []
            }
            if Task.isCancelled { return }
            self.items = result
            self.currentPage = 0
            // Preserve selection if still present, else select the first row
            // of the current (= 0) page.
            if let s = self.selectedID, result.contains(where: { $0.id == s }) {
                // keep
            } else {
                self.selectedID = self.pageItems.first?.id
            }
        }
    }

    /// Move the selection within the current page, auto-flipping pages at the
    /// boundary so a steady stream of ↓ presses still reaches the bottom.
    func moveSelection(by delta: Int) {
        let visible = pageItems
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(where: { $0.id == selectedID }) ?? 0
        let target = currentIdx + delta
        if target < 0 {
            if currentPage > 0 {
                currentPage -= 1
                selectedID = pageItems.last?.id
            }
            return
        }
        if target >= visible.count {
            if currentPage + 1 < pageCount {
                currentPage += 1
                selectedID = pageItems.first?.id
            }
            return
        }
        selectedID = visible[target].id
    }

    /// Page navigation (← / →). No-op at the first / last page.
    func nextPage() {
        guard currentPage + 1 < pageCount else { return }
        currentPage += 1
        selectedID = pageItems.first?.id
    }

    func prevPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
        selectedID = pageItems.first?.id
    }

    /// 1-based index for ⌘1 – ⌘9. Indexes into the **current page**, so the
    /// digit shown on each visible row is always its real shortcut.
    func selectIndex(_ n: Int) {
        let idx = n - 1
        let visible = pageItems
        guard visible.indices.contains(idx) else { return }
        selectedID = visible[idx].id
        paste()
    }

    func selectedItem() -> ClipItem? {
        items.first(where: { $0.id == selectedID })
    }

    /// Fire the paste callback for the currently selected row. Closes the
    /// panel as a side-effect so the host can post `⌘V` to the previously
    /// frontmost app.
    func paste() {
        guard let item = selectedItem() else { return }
        onPasteCallback(item)
        close()
    }

    func togglePinSelected() async {
        guard let id = selectedID else { return }
        do { try store.togglePin(id: id) } catch { return }
        reload()
    }

    /// Toggle pin on a specific row (used by the right-click context menu so
    /// it acts on the row that was right-clicked, not the previously selected
    /// row).
    func togglePin(item: ClipItem) async {
        guard let id = item.id else { return }
        do { try store.togglePin(id: id) } catch { return }
        reload()
    }

    /// Delete a specific row. Pinned rows still go through `confirmIfPinned`.
    func delete(item: ClipItem, confirmIfPinned: () async -> Bool) async {
        guard let id = item.id else { return }
        if item.pinned {
            let ok = await confirmIfPinned()
            if !ok { return }
        }
        do { try store.delete(id: id) } catch { return }
        reload()
    }

    /// Copy the item's content back onto the system pasteboard without
    /// triggering a paste. The next observer tick will dedup against the
    /// existing row and bump its `last_seen_at`, naturally promoting the
    /// item to the top of the recents list.
    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.content, forType: .string)
    }

    /// Delete the selected row. If the row is pinned, call `confirmIfPinned`
    /// first; on `false` the deletion is aborted.
    func deleteSelected(confirmIfPinned: () async -> Bool) async {
        guard let item = selectedItem(), let id = item.id else { return }
        if item.pinned {
            let ok = await confirmIfPinned()
            if !ok { return }
        }
        do { try store.delete(id: id) } catch { return }
        // Keep selection on the row that takes the deleted row's place.
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let nextIdx = min(idx, items.count - 2)
            if nextIdx >= 0 && items.count > 1 {
                selectedID = items[items.index(items.startIndex, offsetBy: nextIdx + (nextIdx == idx ? 1 : 0))].id
            } else {
                selectedID = nil
            }
        }
        reload()
    }

    func close() {
        searchTask?.cancel()
        shouldClose = true
    }

    /// Reset transient state when the panel is shown again.
    func prepareForShow() {
        shouldClose = false
        query = ""
        selectedID = nil
        reload()
    }
}
