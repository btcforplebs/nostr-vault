import Foundation

/// The nostrconnect:// request a signer app scans or opens (NIP-46,
/// client-initiated). Pure so it can be tested without the Go library that
/// makes the key pair.
enum NostrConnectURI {
    static let perms = "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt"

    static func build(clientPubkey: String, secret: String, relays: [String], callback: String?) -> String? {
        var components = URLComponents()
        components.scheme = "nostrconnect"
        components.host = clientPubkey
        var items = relays.map { URLQueryItem(name: "relay", value: $0) }
        items += [
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "perms", value: perms),
            URLQueryItem(name: "name", value: "Nostr Vault"),
            URLQueryItem(name: "url", value: "https://nostrvault.app"),
            URLQueryItem(name: "image", value: "https://nostrvault.app/assets/haven_icon.png"),
        ]
        if let callback {
            items.append(URLQueryItem(name: "callback", value: callback))
        }
        components.queryItems = items
        // URLComponents leaves ":" and "/" in query values as-is; signers
        // (Clave's parser included) read them fine, but encode "+" which some
        // decoders turn into a space.
        return components.string?.replacingOccurrences(of: "+", with: "%2B")
    }
}

/// Where the signer is: this device (hand off to Clave, which sends us back)
/// or another device (show a code to scan). Pure so the per-platform rule is
/// tested: a device that can't open the signer itself (the Mac) always shows
/// the code, whichever button asked.
enum NostrConnectTarget: Equatable {
    case thisDevice
    case otherDevice

    static func resolve(_ requested: NostrConnectTarget, canOpenSignerHere: Bool) -> NostrConnectTarget {
        canOpenSignerHere ? requested : .otherDevice
    }

    /// Only the same-device hand-off may carry `callback=`: a signer on
    /// another device must not be told to open nostrvault:// there.
    var includesCallback: Bool { self == .thisDevice }

    /// The QR (and "Copy link") is drawn exactly when the signer is elsewhere.
    var showsCode: Bool { self == .otherDevice }
}
