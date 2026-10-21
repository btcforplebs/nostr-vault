import Foundation

/// Per-account NIP-46 remote signer configuration.
struct AccountBunkerConfig: Codable, Equatable {
    var bunkerURI: String = ""
    var signerPubkey: String = ""
    var relayURL: String = ""
    var secret: String = ""
    var clientSecretKey: String = ""
    var clientPubkey: String = ""
}
