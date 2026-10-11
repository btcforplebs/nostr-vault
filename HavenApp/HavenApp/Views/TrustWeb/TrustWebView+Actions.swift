import SwiftUI

extension TrustWebView {
    // MARK: - Actions

    func tapped(_ pubkey: String) {
        // The globe answers "can I trust them?" in a card, in the WOT tab and
        // the popup alike; only the card's "See their web" moves the globe.
        pubkey == me || pubkey == card ? closeCard() : openCard(pubkey)
    }

    /// Puts `pubkey` in the middle with everyone they follow around them,
    /// one step further along the trail.
    func center(on pubkey: String) {
        if let index = crumbs.firstIndex(of: pubkey) { return jump(to: index) }
        crumbs.append(pubkey)
        guard frames[pubkey] == nil else { return }
        nostrService.fetchMissingProfiles(for: [pubkey])
        Task {
            let list = await TrustPathService.shared.followList(of: pubkey)
            let ring = list ?? []
            let found = await TrustPathService.shared.path(for: author, from: pubkey, follows: ring)
            frames[pubkey] = Frame(center: pubkey, ring: ring, listFound: list != nil, path: found)
            nostrService.fetchMissingProfiles(for: [pubkey] + found.bridges)
            prepareFaces(pubkey)
        }
    }

    func jump(to index: Int) {
        guard index < crumbs.count - 1 else { return }
        crumbs = Array(crumbs.prefix(index + 1))
    }

    // MARK: - Helpers

    func avatar(_ pubkey: String, _ size: CGFloat) -> AnyView {
        AnyView(AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size))
    }

    func name(_ pubkey: String) -> String {
        if pubkey == me { return "You" }
        return nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }
}
