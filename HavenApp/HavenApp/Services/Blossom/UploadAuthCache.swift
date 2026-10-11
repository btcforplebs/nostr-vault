import Foundation
import CryptoKit
import os.log

/// Pre-signed BUD-02 upload authorisations, by signing account and blob hash.
///
/// Shared rather than held per `BlossomService` on purpose: the views build a
/// fresh service on every access (`ComposeView.blossomService` is a computed
/// property), so an instance-held cache would be thrown away between
/// pre-signing an attachment's authorisation and uploading the blob.
///
/// An authorisation is scoped to `t: upload` and `x: <sha256>` and nothing
/// else — not to a request, not to a server — so one signature is good for
/// every request that blob needs until it expires, including a retry of a
/// failed post.
actor UploadAuthCache {
    static let shared = UploadAuthCache()

    private struct Prepared {
        let base64: String
        let expiresAt: Int64
    }
    private var prepared: [String: Prepared] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// The authorisation for `signer` and `sha256`, signing one through `sign`
    /// if there is none to reuse. Callers that arrive while a signature is
    /// out — the upload catching up with its own pre-sign — wait for that one
    /// answer instead of putting a second request to the signer.
    func authorisation(signer: String, sha256: String,
                       sign: @escaping @Sendable () async -> (base64: String, expiresAt: Int64)?) async -> String? {
        let key = signer + ":" + sha256
        let now = Int64(Date().timeIntervalSince1970)
        if let entry = prepared[key] {
            // Keep a wide margin: an authorisation that expires mid-upload is
            // worse than one more signature here, and a large video can take
            // minutes to reach every mirror.
            if entry.expiresAt - now > 600 { return entry.base64 }
            prepared[key] = nil
        }
        if let outstanding = inFlight[key] { return await outstanding.value }

        let task = Task<String?, Never> { [weak self] in
            guard let signed = await sign() else { return nil }
            await self?.store(key: key, base64: signed.base64, expiresAt: signed.expiresAt)
            return signed.base64
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func store(key: String, base64: String, expiresAt: Int64) {
        prepared[key] = Prepared(base64: base64, expiresAt: expiresAt)
        prune()
    }

    /// Nothing clears this cache on an account switch and nothing needs to —
    /// the signing pubkey is part of the key, so an entry can only ever be
    /// handed back to the account that signed it. This just keeps the map from
    /// growing for the life of the process.
    private func prune() {
        let now = Int64(Date().timeIntervalSince1970)
        prepared = prepared.filter { $0.value.expiresAt > now }
        guard prepared.count > Self.maxPrepared else { return }
        let keep = prepared.sorted { $0.value.expiresAt > $1.value.expiresAt }
            .prefix(Self.maxPrepared)
        prepared = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private static let maxPrepared = 32
}
