import SwiftUI

extension SearchView {
    /// Recomputes "For you" into cached state. Called from `refreshDiscovery`,
    /// so it shares its throttle.
    func refreshRecommendations() {
        if feedService.wotVouches == nil, !feedService.wotCacheRead { feedService.loadWotPubkeys() }
        let owner = configService.activeAccountHexPubkey
        let blocked = configService.activeAccountBlockedHexPubkeys
        let following = Set(feedService.followedPubkeys)
        let vouches = feedService.wotVouches ?? [:]

        let people = SearchRecommendations.people(vouches: vouches, following: following,
                                                  owner: owner, blocked: blocked)
        cachedRecommendedPeople = people
        nostrService.fetchMissingProfiles(for: people.map(\.pubkey))

        let notes = feedService.notes
        let reacted = Set(feedService.myReactions.keys)
        let engaged = notes.filter { $0.pubkey == owner || reacted.contains($0.id) }.map(\.tags)
        let topics = SearchRecommendations.interests(followed: InterestListService.shared.hashtags,
                                                     engaged: engaged)
        cachedTopics = topics

        let picked = SearchRecommendations.notes(
            notes.map { .init(id: $0.id, pubkey: $0.pubkey, tags: $0.tags, createdAt: $0.createdAt) },
            interests: Set(topics), following: following, vouches: vouches,
            owner: owner, blocked: blocked, seen: reacted
        )
        let byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedPickedNotes = visibleNotes(picked.compactMap { byId[$0] }, blockFilter)
    }

    @ViewBuilder
    var recommendationsSection: some View {
        SearchRecommendationsSection(
            people: cachedRecommendedPeople,
            topics: cachedTopics,
            notes: cachedPickedNotes,
            onProfile: { showingProfile = $0 },
            onTopic: { tag in if let url = HashtagLink.url(for: tag) { openURL(url) } },
            onNote: { openNote($0) },
            onMedia: { url, urls in showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) }
        )
    }
}
