import SwiftUI

/// Save for later (kind 10003): a shared link goes on the account's Bookmarks
/// list, publicly or privately. Written through the Bookmarks store's own
/// merged-list path (`NostrService.publishMergedList`, as
/// `NostrService.publishBookmark`), never a list of its own: the newest list
/// the account's relays agree on is fetched at the tap, only this one `r` tag
/// is added, and a private part this device can't open is never written
/// over. Private entries are NIP-44 encrypted to the account itself. Tron
/// review (private bookmarks). Twin: BookmarkShareHandler.kt.
struct BookmarkShareHandler: SharePortalHandler {
    let action = NVShareAction.bookmark

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(BookmarkShareReviewView(intent: intent, close: close))
    }
}

extension BookmarkShareHandler {
    enum Outcome: Equatable {
        case saved(privately: Bool)
        case alreadyPublic
        case alreadyPrivate
        /// Not signed or not sent; `why` is said on the card.
        case failed(String)
    }

    /// The link the share saves, if it named one.
    static func url(for intent: NVShareIntent) -> String? {
        BookmarkShareTags.url(NVShareClassifier.webURL(of: NVShareInput(url: intent.source.url, text: intent.source.text)))
    }

    /// Adds `url` to the active account's bookmarks. The card only offers
    /// this for the account the share was meant for, once it is the active one.
    @MainActor
    static func save(_ url: String, privately: Bool) async -> Outcome {
        guard ConfigService.shared.activeAccountCanSign else { return .failed("This account is read-only here.") }
        let hex = ConfigService.shared.activeAccountHexPubkey
        let config = ConfigService.shared.config
        let npub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        guard !hex.isEmpty else { return .failed("No account is signed in.") }

        var result: Outcome?
        let event = await NostrService.shared.publishMergedList(kind: BookmarkShareTags.kind, author: hex, signAsNpub: npub,
                                                                skipIfUnchanged: true) { published in
            let tags = published?.tags ?? []
            let content = published?.content ?? ""
            // The private part, opened with this account's key; unreadable → nothing is written.
            var privateTags: [[String]] = []
            if !content.isEmpty {
                let nip04 = content.contains("?iv=")
                guard let plain = try? await MuteListStore.decryptToSelf(content, me: hex, nip04: nip04),
                      let open = BookmarkShareTags.privateTags(plaintext: plain) else {
                    result = .failed("Your private bookmarks couldn't be opened here, so nothing was changed.")
                    return (tags, content)
                }
                privateTags = open
            }
            switch BookmarkShareTags.adding(url, publicTags: tags, privateTags: privateTags, privately: privately) {
            case .alreadyPublic:
                result = .alreadyPublic
                return (tags, content)
            case .alreadyPrivate:
                result = .alreadyPrivate
                return (tags, content)
            case .publicTags(let next):
                return (next, content)
            case .privateTags(let next):
                // NIP-44 to self, as every app's list merge saves a private part.
                guard let sealed = try? await MuteListStore.encryptToSelf(BookmarkShareTags.json(next), me: hex, nip04: false) else {
                    result = .failed("Your signer couldn't encrypt the private bookmark, so nothing was changed.")
                    return (tags, content)
                }
                return (tags, sealed)
            }
        }
        if let result { return result }
        guard let event, event.pubkey == hex, event.kind == BookmarkShareTags.kind else {
            return .failed("Not saved: your relays didn't answer, or your signer didn't sign.")
        }
        // The Bookmarks page and the note menus read the new list.
        await BookmarkService.shared.refresh(force: true)
        return .saved(privately: privately)
    }
}
