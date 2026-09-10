import Foundation

/// Parsing for NIP-46 `bunker://` connection strings.
///
/// Pure Foundation and free of app types so it can be unit tested (see
/// `MediaLogicTests`) and called from anywhere, including a QR scanner
/// callback that needs to decide whether a scanned code is usable before it
/// touches the field.
enum BunkerURI {
    struct Info: Equatable {
        let signerPubkey: String
        let relayURL: String
        let secret: String
    }

    /// Parses a bunker connection string, or returns nil if it is not one.
    /// Accepts the single-slash `bunker:` spelling some signers emit.
    static func parse(_ uri: String) -> Info? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        var workingURI = trimmed
        if trimmed.hasPrefix("bunker://") {
            // standard format
        } else if trimmed.hasPrefix("bunker:") {
            let suffix = trimmed.dropFirst("bunker:".count)
            workingURI = "bunker://\(suffix)"
        } else {
            return nil
        }

        guard let components = URLComponents(string: workingURI) else { return nil }

        let signerPubkey = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !signerPubkey.isEmpty,
              signerPubkey.count == 64,
              signerPubkey.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            return nil
        }

        guard let queryItems = components.queryItems,
              let relayString = queryItems.first(where: { $0.name == "relay" })?.value,
              !relayString.isEmpty else {
            return nil
        }

        let secret = queryItems.first(where: { $0.name == "secret" })?.value ?? ""

        return Info(
            signerPubkey: signerPubkey,
            relayURL: relayString.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: secret
        )
    }

    /// Normalises text that is meant to be a bunker connection string — pasted,
    /// or scanned off a signer's QR code — and returns nil when it is not one,
    /// so a wrong code can be rejected at the field instead of failing on
    /// Connect.
    static func normalized(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("nostr:") {
            candidate = String(candidate.dropFirst("nostr:".count))
        }
        if candidate.hasPrefix("bunker:") && !candidate.hasPrefix("bunker://") {
            candidate = "bunker://" + candidate.dropFirst("bunker:".count)
        }
        guard parse(candidate) != nil else { return nil }
        return candidate
    }
}
