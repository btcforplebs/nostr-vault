import Foundation
import Security

/// What a factory reset must clear of the FIPS mesh, on the iPhone and the
/// Mac: the mesh key (its own nsec, so the mesh npub readers dial) and the
/// `fipsMesh.*` switches. Afterwards the next engine start makes a new key,
/// as on a fresh install. The engines themselves are stopped by their
/// services first (`FipsMeshService` / `MacFipsMeshService.stopForReset()`).
enum MeshIdentityReset {
    /// The keychain service both engines keep the mesh key under.
    static let keychainService = "to.nostrvault.fipsmesh"
    static let defaultsPrefix = "fipsMesh."

    static func clear(defaults: UserDefaults = .standard, keychainService: String = keychainService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(defaultsPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
