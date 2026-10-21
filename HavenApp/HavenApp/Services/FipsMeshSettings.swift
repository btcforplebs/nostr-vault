#if os(iOS)
import Foundation

/// The iPhone's FIPS Mesh switches. Kept in UserDefaults, as the serve limit
/// is, because the engine reads them off the main thread at each start.
enum FipsMeshSettings {
    private static let enabledKey = "fipsMesh.enabled"
    private static let finderRelaysKey = "fipsMesh.finderRelays"
    private static let middleServerKey = "fipsMesh.middleServer"
    private static let listInServersKey = "fipsMesh.listInServers"

    /// Off: nothing starts the engine, so this phone neither reaches nor
    /// shares on the mesh. On by default, as the mesh was before the switch.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Advert and signaling relays for every engine start.
    static var finderRelays: [String] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: finderRelaysKey) ?? []
            return stored.isEmpty ? MeshDevicesLogic.defaultFinderRelays : stored
        }
        set {
            // Empty would hand the engine its own defaults, which carry no
            // offers here; keep ours instead.
            if newValue.isEmpty || newValue == MeshDevicesLogic.defaultFinderRelays {
                UserDefaults.standard.removeObject(forKey: finderRelaysKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: finderRelaysKey)
            }
        }
    }

    static var middleServer: MeshMiddleServer {
        get { MeshMiddleServer(rawValue: UserDefaults.standard.string(forKey: middleServerKey) ?? "") ?? .publicSeeds }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: middleServerKey) }
    }

    /// Kiosk mode lists this phone's mesh address in the owner's 10063.
    static var listInServers: Bool {
        get { UserDefaults.standard.object(forKey: listInServersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: listInServersKey) }
    }

    static func resetAdvanced() {
        UserDefaults.standard.removeObject(forKey: finderRelaysKey)
        UserDefaults.standard.removeObject(forKey: middleServerKey)
    }
}
#endif
