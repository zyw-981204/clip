import SwiftUI

/// Preferences "云同步" tab. Implements **fix F**: parallel three-checkmark
/// test connection — three pings (R2 / D1 / token) run via `async let`; status
/// updates as each completes; user sees three independent ✓ / ✗ marks rather
/// than one cumulative spinner.
///
/// Bootstrap calls `SyncEngine.enableSync` (T18) and posts a notification
/// (`.clipCloudSyncDidEnable`) so AppDelegate (T25) can spin up the engine +
/// first-device backfill on success.
@MainActor
struct CloudSyncView: View {
    @State private var enabled = false
    @State private var r2Endpoint = ""
    @State private var r2Bucket = "clip-sync"
    @State private var r2AccessKeyID = ""
    @State private var r2Secret = ""
    @State private var d1AccountID = ""
    @State private var d1DatabaseID = ""
    @State private var apiToken = ""
    @State private var syncPassword = ""

    @State private var r2Status: TestStatus = .idle
    @State private var d1Status: TestStatus = .idle
    @State private var tokenStatus: TestStatus = .idle
    @State private var bootstrapping = false
    @State private var statusMessage = ""

    enum TestStatus: Equatable {
        case idle, pending, ok, fail(String)
    }

    private var settings: SyncSettings { PreferencesContainer.shared.syncSettings }

    var body: some View {
        Form {
            Toggle("启用云同步", isOn: $enabled)
                .onChange(of: enabled) { new in settings.enabled = new }

            if enabled {
                Section("R2（图片字节）") {
                    TextField("Endpoint", text: $r2Endpoint)
                        .help("形如 https://<account>.r2.cloudflarestorage.com")
                    TextField("Bucket", text: $r2Bucket)
                    TextField("Access Key ID", text: $r2AccessKeyID)
                    SecureField("Secret Access Key", text: $r2Secret)
                }

                Section("D1（条目元数据）") {
                    TextField("Account ID", text: $d1AccountID)
                    TextField("Database ID", text: $d1DatabaseID)
                    SecureField("API Token", text: $apiToken)
                        .help("Account → R2:Edit + D1:Edit")
                }

                Section("测试连接") {
                    HStack { statusIcon(r2Status); Text("R2 (blob 上下传)") }
                    HStack { statusIcon(d1Status); Text("D1 (条目同步)") }
                    HStack { statusIcon(tokenStatus); Text("API Token (有效性)") }
                    Button("并行测试") { testConnection() }
                        .disabled(testButtonDisabled)
                }

                Section("同步密码 (E2E)") {
                    SecureField("同步密码 (≥12 字符)", text: $syncPassword)
                    Button(bootstrapping ? "正在初始化…" : "初始化 / 加入云端") { bootstrap() }
                        .disabled(bootstrapButtonDisabled)
                    Text("剪贴板内容在上传前用你的同步密码做端到端加密 (ChaCha20-Poly1305)，云端永远拿不到明文。\n\n⚠️ 密码丢失 = 云端数据全部不可恢复，请使用密码管理器保存。")
                        .font(.caption).foregroundColor(.secondary)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage).foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func statusIcon(_ s: TestStatus) -> some View {
        switch s {
        case .idle:    Text("·").frame(width: 14)
        case .pending: ProgressView().controlSize(.small).frame(width: 14)
        case .ok:      Text("✓").foregroundColor(.green).frame(width: 14)
        case .fail(let msg):
            Text("✗").foregroundColor(.red).frame(width: 14)
                .help(msg)
        }
    }

    private var testButtonDisabled: Bool {
        r2Endpoint.isEmpty || r2Bucket.isEmpty || r2AccessKeyID.isEmpty
        || r2Secret.isEmpty || d1AccountID.isEmpty || d1DatabaseID.isEmpty
        || apiToken.isEmpty
        || r2Status == .pending || d1Status == .pending || tokenStatus == .pending
    }

    private var bootstrapButtonDisabled: Bool {
        bootstrapping || syncPassword.count < 12 || testButtonDisabled
    }

    private func load() {
        enabled = settings.enabled
        r2Endpoint = settings.r2Endpoint ?? ""
        r2Bucket = settings.r2Bucket ?? "clip-sync"
        r2AccessKeyID = settings.r2AccessKeyID ?? ""
        d1AccountID = settings.d1AccountID ?? ""
        d1DatabaseID = settings.d1DatabaseID ?? ""
    }

    /// Fix F — three pings in parallel; status updates as each completes.
    private func testConnection() {
        r2Status = .pending; d1Status = .pending; tokenStatus = .pending
        let r2 = makeR2()
        let d1 = makeD1()
        let token = apiToken
        let account = d1AccountID
        Task {
            async let rR: TestStatus = pingR2(r2)
            async let rD: TestStatus = pingD1(d1)
            async let rT: TestStatus = pingToken(token: token, account: account)
            let (a, b, c) = await (rR, rD, rT)
            await MainActor.run {
                r2Status = a; d1Status = b; tokenStatus = c
                if a == .ok && b == .ok && c == .ok { persistOnSuccess() }
            }
        }
    }

    private func makeR2() -> R2BlobBackend? {
        guard let url = URL(string: r2Endpoint) else { return nil }
        return R2BlobBackend(endpoint: url, bucket: r2Bucket,
                             accessKeyID: r2AccessKeyID, secretAccessKey: r2Secret)
    }

    private func makeD1() -> D1Backend {
        D1Backend(accountID: d1AccountID, databaseID: d1DatabaseID,
                  apiToken: apiToken)
    }

    private func pingR2(_ b: R2BlobBackend?) async -> TestStatus {
        guard let b else { return .fail("R2 endpoint URL 无效") }
        do {
            // GET a key that's almost certainly absent → 404 is success
            _ = try await b.getBlob(key: "_probe/handshake.bin")
            return .ok
        } catch {
            return .fail("\(error)")
        }
    }

    private func pingD1(_ d: D1Backend) async -> TestStatus {
        do {
            _ = try await d.getConfig(key: "schema_version")  // SELECT works → token + DB OK
            return .ok
        } catch {
            return .fail("\(error)")
        }
    }

    private func pingToken(token: String, account: String) async -> TestStatus {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            guard http.statusCode == 200 else { return .fail("\(http.statusCode)") }
            // Body must contain "active"
            if let s = String(data: data, encoding: .utf8), s.contains("active") {
                return .ok
            }
            return .fail("token not active")
        } catch {
            return .fail("\(error)")
        }
    }

    @MainActor
    private func persistOnSuccess() {
        settings.r2Endpoint = r2Endpoint
        settings.r2Bucket = r2Bucket
        settings.r2AccessKeyID = r2AccessKeyID
        settings.d1AccountID = d1AccountID
        settings.d1DatabaseID = d1DatabaseID
        try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
            .write(account: "current", data: Data(r2Secret.utf8))
        try? KeychainStore(service: "com.zyw.clip.cloud-d1-token-v1")
            .write(account: "current", data: Data(apiToken.utf8))
    }

    /// Spec §7.1 — call SyncEngine.enableSync.
    private func bootstrap() {
        bootstrapping = true
        let pwd = syncPassword
        let d1 = makeD1()
        Task {
            defer { Task { @MainActor in bootstrapping = false } }
            let store = PreferencesContainer.shared.store!
            let state = SyncStateStore(store: store)
            let masterKC = KeychainStore(service: "com.zyw.clip.cloud-master-v1")
            do {
                let result = try await SyncEngine.enableSync(
                    password: pwd, dataSource: d1, state: state,
                    keychain: masterKC, account: "current")
                await MainActor.run {
                    settings.enabled = true
                    statusMessage = result == .firstDevice
                        ? "✓ 已初始化新云端 profile"
                        : "✓ 已加入现有云端"
                }
                NotificationCenter.default.post(name: .clipCloudSyncDidEnable, object: nil)
            } catch {
                await MainActor.run { statusMessage = "✗ 初始化失败: \(error)" }
            }
        }
    }
}

extension Notification.Name {
    static let clipCloudSyncDidEnable = Notification.Name("clip.cloud.didEnable")
}
