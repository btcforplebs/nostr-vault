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

    /// "Found by <name>" for My Web when more than one desktop is paired,
    /// so it says which one ranked (Desktop Vaults P4, plan §6.1); nil with
    /// one desktop, or one with no name, where "your desktop Vault" is clear.
    static func foundBy(_ desktop: MeshDevice?, devices: [MeshDevice]) -> String? {
        guard devices.filter({ $0.role == .mac }).count > 1,
              let name = desktop?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return "Found by \(name)"
    }

    /// A hand-off row's name: the device's own name (the desktop's My
    /// Devices, else this device's), "This device" for an unnamed self, and
    /// its type only when it has no name anywhere.
    static func handoffName(_ h: VaultStatus.Handoff, devices: [MeshDevice], selfHex: String?) -> String {
        if let name = h.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let local = devices.first { npubHex($0.npub) == h.device }?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local, !local.isEmpty { return local }
        if let selfHex, h.device == selfHex.lowercased() { return "This device" }
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
