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
    @Published var query: String = ""
    @Published private(set) var items: [ClipItem] = []
    @Published var selectedID: Int64?
    /// Set to `true` by `close()`; `PanelView` (or its host) observes and
    /// closes the panel window. Reset to `false` each time the panel is shown.
    @Published var shouldClose: Bool = false

    private let store: HistoryStore
    private let onPasteCallback: (ClipItem) -> Void
    private var searchTask: Task<Void, Never>?

    init(store: HistoryStore, onPaste: @escaping (ClipItem) -> Void) {
        self.store = store
        self.onPasteCallback = onPaste
    }

    /// Trigger a debounced search/listRecent load. Safe to call repeatedly.
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
            // Preserve selection if still present, else select the first row.
            if let s = self.selectedID, result.contains(where: { $0.id == s }) {
                // keep
            } else {
                self.selectedID = result.first?.id
            }
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = max(0, min(items.count - 1, currentIdx + delta))
        selectedID = items[next].id
    }

    /// 1-based index for ⌘1 – ⌘9.
    func selectIndex(_ n: Int) {
        let idx = n - 1
        guard items.indices.contains(idx) else { return }
        selectedID = items[idx].id
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
