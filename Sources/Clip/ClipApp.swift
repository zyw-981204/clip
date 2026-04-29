import SwiftUI
import AppKit

@main
struct ClipApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
