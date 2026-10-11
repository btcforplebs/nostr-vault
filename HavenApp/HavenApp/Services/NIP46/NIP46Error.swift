import Foundation

// MARK: - NIP-46 Error Types

enum NIP46Error: Error, LocalizedError {
    case notConnected
    case timeout
    case rejected(String)
    case offline
    case signerError(String)
    case authChallenge(String)
    case invalidResponse
    case invalidBunkerURI
    case encryptionFailed
    case signingFailed
    case wrongAccount(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to remote signer"
        case .timeout: return "Your signer didn't answer in time. Open it and check for a pending request."
        case .rejected(let msg): return msg.isEmpty ? "Your signer declined the request" : "Your signer declined the request: \(msg)"
        case .offline: return "Couldn't reach your signer's relay. Check your connection."
        case .signerError(let msg): return "Signer error: \(msg)"
        case .authChallenge(let url): return "Signer requires verification: \(url)"
        case .invalidResponse: return "Invalid response from signer"
        case .invalidBunkerURI: return "Invalid bunker:// URI"
        case .encryptionFailed: return "Failed to encrypt NIP-46 request"
        case .signingFailed: return "Failed to sign NIP-46 request event"
        case .wrongAccount(let expected, let got):
            return "This signer is for a different account (\(got.prefix(8))…), not \(expected.prefix(8))…"
        }
    }
}
