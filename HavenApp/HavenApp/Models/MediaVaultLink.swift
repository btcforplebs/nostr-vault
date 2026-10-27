import Foundation

/// Whether a note photo's link is the owner's vault itself — a NIP-F1 `.fips`
/// name, which only the mesh reaches — rather than an ordinary https server.
///
/// Decides what a photo that failed to load says: a vault link gets
/// "Couldn't reach the owner's vault"; anything else is a plain broken image,
/// since blaming the owner's vault for some other server's failure is wrong.
/// Same rule as the web's `afterMeshFail` (web-vault MediaImage.jsx).
enum MediaVaultLink {
    static func isVault(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".fips") || host.hasSuffix(".fips.")
    }

    static let unreachedText = "Couldn't reach the owner's vault"
}
