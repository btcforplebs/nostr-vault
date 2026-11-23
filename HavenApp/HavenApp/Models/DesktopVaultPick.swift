import Foundation

/// Which of My Devices is this phone's desktop Vault, for "Your desktop
/// Vault": a desktop (`.mac`, a Mac or a Linux box) this device has caught
/// up with, the latest first; else the first desktop listed. Pure, so
/// MediaLogicTests checks it. Android twin: `DesktopVaultPick.kt`.
enum DesktopVaultPick {
    static func desktop(_ devices: [MeshDevice], lastSync: [String: Int]) -> MeshDevice? {
        let desktops = devices.filter { $0.role == .mac }
        let synced = desktops.filter { (lastSync[$0.npub] ?? 0) > 0 }
        return synced.max { (lastSync[$0.npub] ?? 0) < (lastSync[$1.npub] ?? 0) } ?? desktops.first
    }

    /// A hand-off row's name: "This device", the My Devices name, or the role.
    static func handoffName(_ h: VaultStatus.Handoff, devices: [MeshDevice], selfHex: String?) -> String {
        if let selfHex, h.device == selfHex.lowercased() { return "This device" }
        if let named = devices.first(where: { npubHex($0.npub) == h.device }) { return named.displayName }
        return h.role.flatMap { MeshDeviceRole(rawValue: $0)?.label } ?? "A paired device"
    }

    /// "Updated just now", "Updated 12 min ago": the age of the copy shown.
    static func updated(_ fetchedAt: Int64, now: Date) -> String {
        "Updated \(VaultStatusText.ago(fetchedAt, now: now))"
    }

    private static func npubHex(_ npub: String) -> String? {
        Bech32.decode(npub)?.hexString.lowercased()
    }
}
