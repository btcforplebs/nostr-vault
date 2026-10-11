import Foundation
import Security
#if os(iOS)
import UIKit
#endif

extension NIP46Service {
    // MARK: - Sign in with a signer app (nostrconnect://)

    /// One pairing attempt in the client-initiated flow: we show a
    /// nostrconnect:// URI carrying our pubkey and a fresh secret, and the
    /// signer app (Clave) answers with that secret. Kept for the whole attempt
    /// so "Open Clave again" re-sends the SAME request — Clave answers an
    /// already-approved one silently instead of asking twice.
    struct NostrConnectRequest {
        let uri: String
        let clientSecretKey: String
        let clientPubkey: String
        let secret: String
        let relays: [String]
        let startedAt: Int
    }

    /// relay.powr.build is the relay Clave's push proxy watches, so a request
    /// there wakes Clave even when it is closed, and it keeps kind 24133 so an
    /// answer sent while we were suspended can be read back. damus keeps them
    /// too.
    nonisolated static let nostrConnectRelays = ["wss://relay.powr.build", "wss://relay.damus.io"]

    /// Where Clave sends the user back after they approve (its `callback=`).
    /// Any nostrvault:// URL just brings the app forward.
    nonisolated static let nostrConnectCallback = "nostrvault://signer-return"

    func makeNostrConnectRequest(includeCallback: Bool) -> NostrConnectRequest? {
        guard let keyPairCStr = GenerateKeyPairC() else { return nil }
        let keyPair = String(cString: keyPairCStr)
        free(keyPairCStr)
        let parts = keyPair.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let clientSK = String(parts[0]), clientPK = String(parts[1])

        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()

        var components = URLComponents()
        components.scheme = "nostrconnect"
        components.host = clientPK
        var items = Self.nostrConnectRelays.map { URLQueryItem(name: "relay", value: $0) }
        items += [
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "perms", value: "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt"),
            URLQueryItem(name: "name", value: "Nostr Vault"),
            URLQueryItem(name: "url", value: "https://nostrvault.app"),
            URLQueryItem(name: "image", value: "https://nostrvault.app/assets/haven_icon.png"),
        ]
        if includeCallback {
            items.append(URLQueryItem(name: "callback", value: Self.nostrConnectCallback))
        }
        components.queryItems = items
        // URLComponents leaves ":" and "/" in query values as-is; signers
        // (Clave's parser included) read them fine, but encode "+" which some
        // decoders turn into a space.
        guard let uri = components.string?.replacingOccurrences(of: "+", with: "%2B") else { return nil }
        return NostrConnectRequest(uri: uri, clientSecretKey: clientSK, clientPubkey: clientPK,
                                   secret: secret, relays: Self.nostrConnectRelays,
                                   startedAt: Int(Date().timeIntervalSince1970) - 5)
    }

    /// Clave's Universal Link for a nostrconnect URI. Opens Clave when it is
    /// installed (without the nostrconnect:// scheme, which any app can claim)
    /// and a page with install links and a QR code when it is not.
    nonisolated static func claveLink(for request: NostrConnectRequest) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = request.uri.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://clave.casa/connect/?uri=\(encoded)")
    }

    /// Waits for the signer's answer to `request`, in short rounds so the
    /// caller's task can be cancelled between them. Returns the signer pubkey.
    func awaitNostrConnect(_ request: NostrConnectRequest, timeout: TimeInterval = 300) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let relaysJSON = (try? String(data: JSONEncoder().encode(request.relays), encoding: .utf8)) ?? "[]"
        while Date() < deadline {
            try Task.checkCancellation()
            let pubkey: String? = await Task.detached {
                guard let cStr = NIP46AwaitNostrConnectC(
                    UnsafeMutablePointer(mutating: (request.clientSecretKey as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (relaysJSON as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (request.secret as NSString).utf8String),
                    Int64(request.startedAt),
                    15
                ) else { return nil as String? }
                let str = String(cString: cStr)
                free(cStr)
                return str
            }.value
            if let pubkey, !pubkey.isEmpty { return pubkey }
        }
        throw NIP46Error.timeout
    }

    /// The bunker:// form of a finished nostrconnect pairing: how every later
    /// reconnect reaches the signer. No secret — the pairing is already made,
    /// and Clave answers a paired app's connect with "ack".
    nonisolated static func bunkerURI(signerPubkey: String, relays: [String]) -> String {
        var components = URLComponents()
        components.scheme = "bunker"
        components.host = signerPubkey
        components.queryItems = relays.map { URLQueryItem(name: "relay", value: $0) }
        return components.string ?? "bunker://\(signerPubkey)"
    }
}
