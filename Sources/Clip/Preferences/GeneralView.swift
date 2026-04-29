import SwiftUI
import ServiceManagement

/// General preferences:
/// - Launch at login via SMAppService.mainApp (macOS 13+).
/// - Panel position picker, persisted in UserDefaults under `clip.panelPosition`.
struct GeneralView: View {
    @AppStorage("clip.panelPosition") private var panelPosition: String = "cursor"
    @State private var loginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var errorText: String?

    var body: some View {
        Form {
            Toggle("开机自启动", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { want in toggleLogin(want) }

            Picker("面板位置", selection: $panelPosition) {
                Text("光标位置").tag("cursor")
                Text("屏幕中心").tag("center")
                Text("上次位置").tag("last")
            }
            .pickerStyle(.inline)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear {
            // Re-sync if the user toggled the login item from System Settings.
            loginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func toggleLogin(_ want: Bool) {
        do {
            if want {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            // Surface the system error and roll the toggle back to actual state.
            errorText = "登录项设置失败：\(error.localizedDescription)"
            loginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }
}
