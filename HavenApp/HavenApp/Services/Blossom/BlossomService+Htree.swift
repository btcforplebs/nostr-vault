import Foundation

extension BlossomService {
    /// Save to Vault for an `htree://` photo (HtreeLink): its decrypted,
    /// checked bytes go into the vault under the plain sha256 the link
    /// carries, the same name a Blossom copy of the photo has. Not the
    /// encrypted blob: the vault keeps files, not someone's ciphertext.
    func saveHtree(url: URL) async -> Bool {
        guard let link = HtreeLink(url),
              let file = await MediaCacheService.shared.htreeFile(url, author: nil),
              let data = try? Data(contentsOf: file),
              let mime = HtreeLink.sniffImage(data)
        else { return false }
        let ok = await saveToLocalRelay(fileURL: file, sha256: link.sha256, contentType: mime, mirrorToExternal: false)
        if ok { await stampCopiedIn(sha256: link.sha256, date: nil) }
        return ok
    }
}
