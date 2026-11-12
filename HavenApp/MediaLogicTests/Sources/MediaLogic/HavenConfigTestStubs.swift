import Foundation

// Stand-ins for the app types HavenConfig names but that cannot build here
// (SwiftUI theming, CryptoKit NIP-49). Bech32 is the real one, symlinked. They
// cover only what HavenConfig touches; nothing the relay-launch tests assert
// on goes through them.

enum AppTheme: String {
    case orange
}

enum NIP49Service {
    enum NIP49Error: Error {
        case decodingFailed
    }

    static func decrypt(ncryptsec: String, password: String) throws -> String {
        throw NIP49Error.decodingFailed
    }

    static func encrypt(nsec: String, password: String) throws -> String {
        throw NIP49Error.decodingFailed
    }
}

/// The Mac's web-domain proof needs the mesh key and the Go signer: here it
/// signs nothing, as a Mac with no mesh key yet (WEB_DOMAIN_PROOF stays "").
enum MeshKeySigner {
    static func domainProofJSON(domain: String) -> String { "" }
}
