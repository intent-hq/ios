import Foundation
import Security

/// Abstraction over Keychain item storage so tests can run hermetically.
protocol KeychainStorage {
    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool
    func load(service: String, account: String) -> Data?
    func delete(service: String, account: String)
}

/// Production backend over the Security framework.
struct SecItemKeychainStorage: KeychainStorage {
    struct SecurityCalls {
        let update: ([String: Any], [String: Any]) -> OSStatus
        let add: ([String: Any]) -> OSStatus
        let delete: ([String: Any]) -> OSStatus

        static let live = Self(
            update: { query, attributes in
                SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            },
            add: { query in SecItemAdd(query as CFDictionary, nil) },
            delete: { query in SecItemDelete(query as CFDictionary) }
        )
    }

    private let security: SecurityCalls

    init(security: SecurityCalls = .live) {
        self.security = security
    }

    @discardableResult
    func save(data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = security.update(query, [kSecValueData as String: data])
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]) { _, new in new }
        return security.add(addQuery) == errSecSuccess
    }

    func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = security.delete(query)
    }
}
