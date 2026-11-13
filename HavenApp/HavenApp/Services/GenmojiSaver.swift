import Foundation
import CryptoKit

/// Saves one Genmoji into one of the account's own emoji sets
/// (RESEARCH/NV_GENMOJI_STARTER_SET.md §2): the PNG goes to the account's
/// public media servers, the set (30030) is merge-saved with it, the set is
/// added to the emoji list (10030) the first time, and a copy is kept in the
/// vault like Save copies does. Upload first, set second: a failed set save
/// leaves an unused image only, never a half-saved set.
@MainActor
final class GenmojiSaver: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case saved(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isWorking: Bool { if case .working = state { return true }; return false }

    func reset() { if !isWorking { state = .idle } }

    /// `png`: the Genmoji (GenmojiImage.largestFramePNG); `title` names a new set.
    func save(png: Data, shortcode: String, d: String, title: String) async {
        let nostr = NostrService.shared
        let me = nostr.activeHexPubkey
        guard FileNote.isHex64(me), ConfigService.shared.activeAccountCanSign else {
            state = .failed("This account can't sign, so it can't publish emoji.")
            return
        }
        let address = GenmojiSets.address(me: me, d: d)

        state = .working("Uploading…")
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let outcome = await EmojiVaultStore.blossom().uploadForPost(data: png, sha256: sha, contentType: "image/png")
        guard case .hosted(let link) = outcome else {
            state = .failed("None of your media servers took the image, so nothing was published. Check Settings → Media servers.")
            return
        }
        let url = link.absoluteString
        guard GenmojiSets.isPublicURL(url), await Self.isReachable(link) else {
            state = .failed("The image isn't reachable at a public link yet, so nothing was published. Try again in a moment.")
            return
        }
        // The account switched while it uploaded: publish nothing for the other one.
        guard nostr.activeHexPubkey == me else { state = .idle; return }

        state = .working("Saving to \(title)…")
        let emoji = CustomEmoji(shortcode: shortcode, url: url, setAddress: address)
        let event = await nostr.publishMergedList(kind: 30030, author: me, signAsNpub: nil, dTag: d) { published in
            if let published { _ = await VaultSocket.publish(published) }
            return (GenmojiSets.setTags(base: published?.tags, d: d, title: title, adding: emoji), published?.content ?? "")
        }
        guard let event else {
            state = .failed("Your set couldn't be read or signed, so it wasn't changed. The image is uploaded; try Save again.")
            return
        }
        _ = await VaultSocket.publish(event)

        let library = EmojiListService.shared
        if !library.library.sets.contains(where: { $0.address == address }) {
            _ = await EmojiVaultStore.shared.setListed(address, on: true)
        } else {
            library.refreshNow()
        }
        _ = await EmojiVaultStore.shared.keep(data: png, mime: "image/png", emoji: [emoji], account: me)
        state = .saved("Saved \(emoji.content) to \(title)")
    }

    /// A HEAD that answers 200: the link really serves the image.
    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
