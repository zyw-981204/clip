import SwiftUI
import AppKit
import GRDB

/// Advanced preferences:
/// - Clear all history (NSAlert confirm → DELETE FROM items).
/// - Reveal the SQLite file in Finder.
///
/// Uses PreferencesContainer.shared for the live HistoryStore + db path.
struct AdvancedView: View {
    @State private var errorText: String?
    @State private var infoText: String?

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Button("清空全部历史", role: .destructive) {
                    confirmAndClearAll()
                }
                Text("钉住的条目也会被一并删除。此操作不可撤销。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 8) {
                Button("打开数据库目录") { revealDB() }
                if let path = PreferencesContainer.shared.dbPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if let infoText {
                Text(infoText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func confirmAndClearAll() {
        let alert = NSAlert()
        alert.messageText = "确认清空全部剪贴板历史？"
        alert.informativeText = "此操作将永久删除所有条目，包含钉住的条目。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let store = PreferencesContainer.shared.store else {
            errorText = "Store 不可用。"
            return
        }
        do {
            try store.pool.write { db in
                try db.execute(sql: "DELETE FROM items")
            }
            errorText = nil
            infoText = "已清空。"
        } catch {
            errorText = "清空失败：\(error.localizedDescription)"
        }
    }

    private func revealDB() {
        guard let path = PreferencesContainer.shared.dbPath else {
            errorText = "数据库路径未知。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
