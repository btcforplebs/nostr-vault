import Foundation
import SilentPaymentsKit

@MainActor
struct SilentPaymentService {

    /// Derive the sp1... silent payment address for any hex pubkey.
    /// No private key needed — works for any user's profile.
    /// Accepts 64-char hex (x-only) or 66-char hex (compressed).
    static func deriveAddress(hexPubkey: String) throws -> String {
        let address = try NostrSilentWalletAdapter.spAddress(fromNpub: hexPubkey)
        return address.address
    }

    /// Create a full wallet (key pair) from the owner's 32-byte hex private key.
    static func createWallet(hexPrivkey: String) throws -> SilentPaymentWallet {
        guard let nsecData = dataFromHex(hexPrivkey), nsecData.count == 32 else {
            throw SilentPaymentError.invalidPrivateKey
        }
        return try SilentPaymentWallet(source: .nostr(nsec: nsecData))
    }

    /// Verify that a given sp1 address matches what would be derived from a hex pubkey.
    static func verifyAddress(_ spAddress: String, forHexPubkey hexPubkey: String) throws -> Bool {
        let expected = try NostrSilentWalletAdapter.spAddress(fromNpub: hexPubkey)
        return expected.address == spAddress
    }

    /// Retrieve the owner's hex private key from config (NIP-49 or plain).
    static func getOwnerHexKey() -> String? {
        let config = ConfigService.shared.config
        if !config.ownerNcryptsec.isEmpty {
            let pwd = NIP49Service.getPasswordFromKeychain()
            return pwd.flatMap { try? config.getDecryptedHexKey(password: $0) }
        } else {
            let key = config.ownerHexKey
            return (key?.isEmpty ?? true) ? nil : key
        }
    }

    // MARK: - Private

    private static func dataFromHex(_ hex: String) -> Data? {
        let h = hex.lowercased()
        guard h.count % 2 == 0 else { return nil }
        var data = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let byte = UInt8(h[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        return data
    }
}
