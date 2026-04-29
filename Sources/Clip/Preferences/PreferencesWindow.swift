import SwiftUI

/// Root of the preferences window. Hosted by an NSWindow + NSHostingController
/// in `AppDelegate.openPreferences()` (the SwiftUI `Settings { }` scene is
/// unreliable in LSUIElement apps).
///
/// We use a segmented `Picker` rather than `TabView` because, when SwiftUI's
/// TabView is hosted in a manually-created NSWindow without a real
/// `NSToolbar`, the tab strip renders directly under the title bar and
/// collides with the traffic-light region.
struct PreferencesWindow: View {
    enum Tab: Hashable, CaseIterable {
        case general, hotkey, retention, privacy, advanced

        var title: String {
            switch self {
            case .general:   "通用"
            case .hotkey:    "热键"
            case .retention: "保留"
            case .privacy:   "隐私"
            case .advanced:  "高级"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .general:   GeneralView()
                case .hotkey:    HotkeyView()
                case .retention: RetentionView()
                case .privacy:   PrivacyView()
                case .advanced:  AdvancedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 440)
    }
}
