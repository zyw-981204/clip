import SwiftUI

/// Root of the SwiftUI `Settings` scene. Five tabs, each a small Form view.
struct PreferencesWindow: View {
    var body: some View {
        TabView {
            GeneralView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            HotkeyView()
                .tabItem { Label("热键", systemImage: "keyboard") }
            RetentionView()
                .tabItem { Label("保留", systemImage: "clock.arrow.circlepath") }
            PrivacyView()
                .tabItem { Label("隐私", systemImage: "hand.raised") }
            AdvancedView()
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 360)
    }
}
