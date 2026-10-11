import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Sign a blob's upload authorisation now, ahead of the upload.
    ///
    /// Called when an attachment is picked. The hash is known at that moment
    /// and the person is still typing, so the signer round trip — a full one,
    /// with a remote signer — is spent where they cannot feel it instead of
    /// after they tap Post. Fire-and-forget: if it has not landed by then, the
    /// upload path signs it as it always did.
    func prepareUploadAuth(sha256: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = await self?.makeUploadAuth(sha256: sha256)
        }
    }

    /// The authorisation for a blob: the pre-signed one when there is one, and
    /// otherwise one signed now.
    func makeUploadAuth(sha256: String) async -> String? {
        // Which key will sign, asked now: an authorisation carries its signer,
        // so one cached under the account the person has since left would put
        // the blob up as that account and tie the two together at the Blossom
        // server.
        let signer = await MainActor.run { self.nostrService.activeHexPubkey }
        return await UploadAuthCache.shared.authorisation(signer: signer, sha256: sha256) { [weak self] in
            guard let self else { return nil }
            return await self.signUploadAuth(sha256: sha256)
        }
    }

    /// Sign one BUD-02 upload authorisation for a blob, to be reused for every
    /// request that blob needs.
    ///
    /// The auth event is scoped to an operation and a hash — `t: upload` and
    /// `x: <sha256>` — not to a request or a server, and the server never reads
    /// its content. So the preflight, the upload, each retry and each mirror
    /// were all signing byte-identical events and throwing them away. With a
    /// NIP-49 encrypted key every one of those is a keychain read plus a
    /// deliberately slow decrypt, stacked up at the moment the user hits post,
    /// and any one of them failing killed the upload.
    ///
    /// Caveat if a mirror is ever added that requires BUD-01's optional
    /// `server` tag: that one needs its own signature, because reuse across
    /// hosts is exactly what such a tag exists to prevent.
    ///
    /// Retries, because a momentary signer problem — a keychain read before the
    /// device has finished unlocking, a NIP-46 bunker mid-reconnect — should
    /// cost a second, not the whole upload.
    private func signUploadAuth(sha256: String) async -> (base64: String, expiresAt: Int64)? {
        let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600
        let authTags = [
            ["t", "upload"],
            ["x", sha256],
            ["expiration", String(expirationTimestamp)]
        ]
        let authContent = "Upload blob \(sha256.prefix(8))..."

        for attempt in 0..<3 {
            guard let authEvent = await nostrService.signEventAsync(kind: 24242, content: authContent, tags: authTags) else {
                let signingMode = await MainActor.run { ConfigService.shared.config.activeSigningMode() }
                appLog("could not sign the upload authorisation (mode \(signingMode)) — attempt \(attempt + 1)/3", level: "WARN")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                return nil
            }
            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event")
                appLog("could not encode the upload authorisation", level: "ERROR")
                return nil
            }
            return (base64: authJSON.base64EncodedString(), expiresAt: expirationTimestamp)
        }
        return nil
    }
}
