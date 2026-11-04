import Foundation
import Security

/// The Live now handoff's keychain item, beside the widget snapshot's (see
/// `NVSharedStore` for why a keychain item and not an App Group). Its own
/// item because a long follow list would bloat every other widget's read.
enum NVLiveNowStore {
    private static let service = "to.nostrvault.widget"
    private static let account = "livenow.v1"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: NVSharedStore.accessGroup,
        ]
    }

    static func load() -> NVLiveHandoff? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NVLiveHandoff.self, from: data)
    }

    @discardableResult
    static func save(_ handoff: NVLiveHandoff) -> Bool {
        guard let data = try? JSONEncoder().encode(handoff) else { return false }
        // AfterFirstUnlock, as the snapshot: the widget refreshes while locked.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
