import Foundation

// Stand-ins for the three app types HavenConfig names but that cannot build
// here (SwiftUI theming, the relay socket's Bech32, CryptoKit NIP-49). They
// cover only what HavenConfig touches; nothing the relay-launch tests assert
// on goes through them.

enum AppTheme: String {
    case orange
}

struct Bech32 {
    struct Decoded {
        let hrp: String
        let hexString: String
    }

    static func decode(_ string: String) -> Decoded? { nil }
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
