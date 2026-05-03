import Foundation
import Security

/// Wrapper around macOS Keychain `kSecClassGenericPassword`. Spec §6.1
/// mandates `kSecAttrSynchronizable=false` — must NOT sync master key
/// through iCloud Keychain (would put Apple in the trust path).
struct KeychainStore: Sendable {
    let service: String
    init(service: String) { self.service = service }

    enum Error: Swift.Error { case keychain(OSStatus) }

    func read(account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.keychain(status) }
        return out as? Data
    }

    func write(account: String, data: Data) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let upd = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if upd == errSecSuccess { return }
        if upd != errSecItemNotFound { throw Error.keychain(upd) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw Error.keychain(st) }
    }

    func delete(account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let st = SecItemDelete(q as CFDictionary)
        if st == errSecItemNotFound || st == errSecSuccess { return }
        throw Error.keychain(st)
    }
}
