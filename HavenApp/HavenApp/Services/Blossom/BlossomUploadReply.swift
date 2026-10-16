import Foundation

/// What an outside Blossom server's answer to `PUT /upload` means.
///
/// BUD-02 says a server that stores the blob answers with a blob descriptor:
/// JSON carrying the blob's `url` and `sha256`. A 2xx without one is not an
/// upload. nostr.build's own website (`https://nostr.build`, and every
/// `<name>.nostr.build` subdomain) answers any `PUT /upload` with `200` and
/// its HTML home page, and serves that same page for `/<sha256>`. Taking the
/// 200 as success put a link to a web page in the note, so the picture never
/// showed (2026-10-16). Its Blossom server is `https://blossom.nostr.build`.
enum BlossomUploadReply {
    /// The link to put in the note, or nil when the reply isn't a stored blob.
    ///
    /// - `onDeviceRelay`: this device's own relay, which is ours and is
    ///   addressed by hash, so `<server>/<sha256>` is right whatever it says.
    static func hostedURL(body: Data, server: URL, sha256: String, onDeviceRelay: Bool) -> URL? {
        if onDeviceRelay {
            return server.appendingPathComponent(sha256)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let urlString = object["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        // A descriptor for some other blob is not this upload.
        if let hash = object["sha256"] as? String, hash.lowercased() != sha256.lowercased() {
            return nil
        }
        return url
    }

    /// For the log: what came back instead of a descriptor.
    static func describe(body: Data, contentType: String?) -> String {
        let type = contentType ?? "no content type"
        let head = String(data: body.prefix(80), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? "(binary)"
        return "\(type): \(head)"
    }
}
