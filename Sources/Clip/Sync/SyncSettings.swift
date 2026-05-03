import Foundation

/// User-facing sync configuration. Non-secrets in UserDefaults; secret R2
/// access key + D1 API token + master key in Keychain (separate stores).
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe (Apple
/// guarantees concurrent reads/writes are atomic), but Foundation does not
/// declare it `Sendable` so Swift 6 strict concurrency cannot verify it.
final class SyncSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let enabled       = "clip.cloud.enabled"
        static let r2Endpoint    = "clip.cloud.r2.endpoint"
        static let r2Bucket      = "clip.cloud.r2.bucket"
        static let r2AccessKeyID = "clip.cloud.r2.access_key_id"
        static let d1AccountID   = "clip.cloud.d1.account_id"
        static let d1DatabaseID  = "clip.cloud.d1.database_id"
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    var r2Endpoint: String? {
        get { defaults.string(forKey: Key.r2Endpoint) }
        set { defaults.set(newValue, forKey: Key.r2Endpoint) }
    }
    var r2Bucket: String? {
        get { defaults.string(forKey: Key.r2Bucket) }
        set { defaults.set(newValue, forKey: Key.r2Bucket) }
    }
    var r2AccessKeyID: String? {
        get { defaults.string(forKey: Key.r2AccessKeyID) }
        set { defaults.set(newValue, forKey: Key.r2AccessKeyID) }
    }
    var d1AccountID: String? {
        get { defaults.string(forKey: Key.d1AccountID) }
        set { defaults.set(newValue, forKey: Key.d1AccountID) }
    }
    var d1DatabaseID: String? {
        get { defaults.string(forKey: Key.d1DatabaseID) }
        set { defaults.set(newValue, forKey: Key.d1DatabaseID) }
    }
}
