import Foundation
import Security
import XCTest
@testable import MediaLogic

/// Reset Everything must leave no mesh key and no `fipsMesh.*` switch behind,
/// so the next start makes a new mesh npub (App Store checklist §2, 2026-10-23).
final class MeshIdentityResetTests: XCTestCase {
    // A throwaway service and defaults suite, so the test never touches the app's own.
    private let service = "to.nostrvault.fipsmesh.test-\(UUID().uuidString)"
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "MeshIdentityResetTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
    }

    private func meshKeyStored() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "mesh-nsec",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    func testResetLeavesNoMeshKeyAndNoMeshSwitches() {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "mesh-nsec",
            kSecValueData as String: Data("nsec1test".utf8),
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        XCTAssertTrue(meshKeyStored(), "the key must be there before the reset, or the test proves nothing")
        for key in ["fipsMesh.enabled", "fipsMesh.ownNpub", "fipsMesh.kioskWanted", "fipsMesh.finderRelays",
                    "fipsMesh.middleServer", "fipsMesh.macEngine", "fipsMesh.macOwnNpub"] {
            defaults.set("x", forKey: key)
        }
        defaults.set("keep", forKey: "browserRelay.v1")

        MeshIdentityReset.clear(defaults: defaults, keychainService: service)

        XCTAssertFalse(meshKeyStored())
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fipsMesh.") }.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "browserRelay.v1"), "keep", "only the mesh prefs go")
    }

    func testTheEnginesUseTheServiceTheResetClears() throws {
        // Both engines must keep the key under the service the reset deletes.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("HavenApp/Services")
        for file in ["FipsMeshService.swift", "MacFipsMeshService.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("MeshIdentityReset.keychainService"), file)
        }
    }
}
