import SwiftUI
import KeyboardShortcuts

/// Hotkey preferences. The Recorder writes directly into the
/// `KeyboardShortcuts.Name.togglePanel` slot so HotkeyManager picks it up
/// without us having to round-trip through UserDefaults.
struct HotkeyView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("唤起面板", name: .togglePanel)
            Text("默认：⌃⌥⌘V。点击右侧记录器后按下新组合即可。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
