import Foundation
import Security

/// Where tailnet auth keys live. A protocol so tests and demo mode never touch
/// the real Keychain.
protocol TailnetAuthKeyStoring: AnyObject {
    func authKey(for id: UUID) -> String?
    func setAuthKey(_ key: String?, for id: UUID) throws
    func storedIDs() -> Set<UUID>
}

/// A reusable auth key can add machines to someone's tailnet, so it is kept
/// out of `state.json` and the iCloud snapshot entirely: this device only,
/// not synchronizable, readable after the first unlock so a background LAN
/// share can still build the profile.
final class TailnetAuthKeyStore: TailnetAuthKeyStoring {
    private let service: String

    init(service: String = "com.jzb.tower.tailnet-auth-key") {
        self.service = service
    }

    struct KeychainError: Error {
        let status: OSStatus
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            // The Mac build would otherwise use the file-based keychain, which
            // ignores the accessibility class below.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func authKey(for id: UUID) -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storedIDs() -> Set<UUID> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) })
    }

    func setAuthKey(_ key: String?, for id: UUID) throws {
        let base = query(for: id)
        guard let key, let data = key.data(using: .utf8) else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// Used by tests and the demo profile.
final class InMemoryTailnetAuthKeyStore: TailnetAuthKeyStoring {
    private var keys: [UUID: String] = [:]

    init(_ keys: [UUID: String] = [:]) { self.keys = keys }

    func authKey(for id: UUID) -> String? { keys[id] }

    func setAuthKey(_ key: String?, for id: UUID) throws { keys[id] = key }

    func storedIDs() -> Set<UUID> { Set(keys.keys) }
}
