import Foundation

/// Hands the engine this device's mesh npub and My Devices (SetMeshDevicesC,
/// docs/MESH_COPY_V2_CONTRACT.md §2): only these devices' mesh keys may start
/// a copy or use Blossom over the mesh here, and a device that leaves the
/// set loses its copy tokens at once. Called when the relay starts and after
/// every My Devices change; the same list the mesh engine gets as
/// `own_devices`.
enum MeshDeviceSetSync {
    @MainActor
    static func push() {
        let config = ConfigService.shared.config
        #if os(iOS)
        let devices = FipsMeshDevices.current(config)
        let own = FipsMeshService.shared.ownMeshNpub
        #else
        let devices = config.meshDevices
        let own = MacFipsMeshService.shared.ownNpub
        #endif
        // The stored mesh npub only: asking the key for it would make one on a
        // device that has never used the mesh. None yet: the engine keeps its
        // set (none at first, which accepts no device).
        guard let json = MeshKeyAuth.deviceSet(selfNpub: own, devices: devices) else { return }
        let rc = json.withCString { SetMeshDevicesC(UnsafeMutablePointer(mutating: $0)) }
        if rc != 0 {
            RelayProcessManager.shared.addLog("Mesh: the engine did not take My Devices (\(rc))", level: "ERROR")
        }
    }
}
