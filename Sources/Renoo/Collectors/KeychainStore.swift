import Foundation
import Security

/// The one Keychain item the SDK owns: the install identity record (install ID kept across reinstalls).
/// A protocol so tests can use an in-memory fake instead of the real Keychain.
protocol KeychainStore: AnyObject {
    /// The stored data, or `nil` when there is no item. Throws when the Keychain can't be read.
    func read() throws -> Data?
    /// Creates or replaces the item.
    func write(_ data: Data) throws
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        switch status {
        case errSecMissingEntitlement:
            return "Keychain error \(status) (missing entitlement; normal in test bundles without a host app)"
        case errSecInteractionNotAllowed:
            return "Keychain error \(status) (device locked since boot)"
        default:
            return "Keychain error \(status)"
        }
    }
}

/// The real Keychain: one generic password item, readable after first unlock,
/// never synced to iCloud and never restored to another device.
final class SystemKeychain: KeychainStore {
    static let service = "dev.renoo.sdk"
    static let account = "install_identity"

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        #if os(macOS)
        // Use the iOS-style keychain on macOS too, so `swift test` never touches the login keychain.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery.merging(attributes) { _, new in new }
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
