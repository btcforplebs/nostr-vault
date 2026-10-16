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
            loadWider(pubkey)
        }
    }

    /// "Open in WoT" from another globe: back to you, then onto them, with
    /// anything open on the tab put away.
    func openRequested() {
        guard frames[me] != nil, let pubkey = WOTOpenRequest.shared.take() else { return }
        clearSearch()
        searchOpen = false
        closeCard()
        myWebOpen = false
        profilePubkey = nil
        messagePubkey = nil
        jump(to: 0)
        if pubkey != me { center(on: pubkey) }
    }

    /// Your follow list changed: redraw your own globe in place, so you stay
    /// wherever you'd gone, and trace the author again so a follow of them
    /// reads "You follow them" here too.
    func foldInFollows() {
        let follows = FeedService.shared.followedPubkeys
        guard Set(follows) != myFollows else { return }
        myFollows = Set(follows)
        frames[me] = refolded(frames[me], ring: follows, path: frames[me]?.path ?? path)
        prepareFaces(me)
        // Someone you unfollowed moves out to the haze; a new follow leaves it.
        recomputeHaze()
        Task {
            let found = await TrustPathService.shared.path(for: author)
            guard FeedService.shared.followedPubkeys == follows else { return }
            frames[me] = refolded(frames[me], ring: follows, path: found)
        }
    }

    /// Your globe on a new follow list, keeping what it had already found.
    private func refolded(_ old: Frame?, ring: [String], path: TrustPath) -> Frame {
        var updated = Frame(center: me, ring: ring, path: path)
        if let old {
            // A bridge you unfollowed is no longer one.
            let follows = Set(ring)
            updated.bridges = Array(Set(old.bridges).union(path.lit)).filter(follows.contains).sorted()
            updated.seen = old.seen.union(path.lit)
            updated.exhausted = old.exhausted
            updated.chains = old.chains
        }
        return updated
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
