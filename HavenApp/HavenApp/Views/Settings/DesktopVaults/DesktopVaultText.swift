import Foundation

/// Words the Desktop Vaults screens share.
enum DesktopVaultText {
    /// "What is this? (NIP-F1)" beside each "Media over the Mesh" switch.
    static let nipF1URL = URL(string: "https://nostrvault.app/docs/developers/#nips")!

    static func icon(_ kind: DesktopVaultKind) -> String {
        switch kind {
        case .mac: return "desktopcomputer"
        case .linux: return "server.rack"
        case .box: return "shippingbox"
        }
    }

    static func kindLabel(_ kind: DesktopVaultKind) -> String {
        switch kind {
        case .mac: return "Mac"
        case .linux: return "Linux"
        case .box: return "Box"
        }
    }

    /// "Mesh and web · vault.example.com", "Mesh only", "Web only · host".
    static func paths(_ vault: DesktopVault) -> String {
        switch (vault.meshNpub != nil, vault.hostKey) {
        case (true, let host?): return "Mesh and web · \(host)"
        case (false, let host?): return "Web only · \(host)"
        default: return "Mesh only"
        }
    }

    /// §2.2 rule 1: what an HTTPS-only Vault holds.
    static let webOnlyNote = "Holds your public posts, photos and messages. Drafts and private files need Mesh."
}
