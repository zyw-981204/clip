import SwiftUI
import AppKit
import KeyboardShortcuts
import ServiceManagement

struct OnboardingWindow: View {
    @AppStorage("clip.onboarded") private var onboarded: Bool = false
    @AppStorage("clip.loginItemPreferred") private var loginItemPreferred: Bool = true
    @State private var page: Int = 0
    @State private var trusted: Bool = AccessibilityCheck.isTrusted(prompt: false)
    @State private var loginError: String?

    /// When true, skip pages 2/3 and only show the Accessibility page.
    let accessibilityOnly: Bool
    let onClose: () -> Void

    init(accessibilityOnly: Bool = false, onClose: @escaping () -> Void = {}) {
        self.accessibilityOnly = accessibilityOnly
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: 480, height: 280)
                .padding(20)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 480, height: 360)
        .onAppear { trusted = AccessibilityCheck.isTrusted(prompt: false) }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: accessibilityPage
        case 1: hotkeyPage
        default: loginItemPage
        }
    }

    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("授予 Accessibility 权限").font(.title2).bold()
            Text("Clip 需要 Accessibility 权限才能在你按下回车后把选中条目自动粘贴到当前 app（合成 ⌘V 按键）。不开启权限的话，内容仍会写入剪贴板，但需要你手动按 ⌘V。")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(trusted ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(trusted ? "已授权" : "未授权")
                    .font(.callout)
            }
            HStack {
                Button("打开系统设置") { AccessibilityCheck.openSystemSettings() }
                Button("我已授权") { trusted = AccessibilityCheck.isTrusted(prompt: false) }
            }
            Spacer()
        }
    }

    private var hotkeyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全局热键").font(.title2).bold()
            Text("默认热键是：")
                .foregroundStyle(.secondary)
            Text(currentHotkeyLabel())
                .font(.system(.title3, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
            Text("可以在「偏好设置 → Hotkey」里录入任意键组合。")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var loginItemPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("开机自启动").font(.title2).bold()
            Toggle("登录时自动启动 Clip（推荐）", isOn: $loginItemPreferred)
            Text("勾选后，「完成」会把 Clip 注册为登录项；之后 macOS 启动时会自动把它放到菜单栏。")
                .foregroundStyle(.secondary)
                .font(.callout)
            if let e = loginError {
                Text(e).foregroundStyle(.red).font(.caption)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if accessibilityOnly {
                Spacer()
                Button("关闭") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("第 \(page + 1) / 3 步").foregroundStyle(.secondary).font(.caption)
                Spacer()
                if page > 0 {
                    Button("上一步") { page -= 1 }
                }
                if page < 2 {
                    Button("下一步") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func currentHotkeyLabel() -> String {
        if let s = KeyboardShortcuts.getShortcut(for: .togglePanel) {
            return s.description
        }
        return "⌃⌥⌘V"
    }

    private func finish() {
        if !accessibilityOnly && loginItemPreferred {
            do {
                try SMAppService.mainApp.register()
            } catch {
                loginError = String(describing: error)
                return
            }
        }
        onboarded = true
        onClose()
    }
}
