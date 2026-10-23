import SwiftUI
import Combine

extension SearchView {
    func saveRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 8 { recentSearches = Array(recentSearches.prefix(8)) }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    private func computeTrendingHashtags() -> [String] {
        var counts: [String: Int] = [:]
        for note in feedService.notes {
            for tag in note.tags where tag.count >= 2 && tag[0] == "t" {
                let hashtag = tag[1].lowercased()
                counts[hashtag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
    }

    private func computeSuggestedProfiles() -> [(String, FeedProfile)] {
        // Profiles that appear most in the feed (most active posters)
        var postCounts: [String: Int] = [:]
        for note in feedService.notes {
            postCounts[note.pubkey, default: 0] += 1
        }
        let ownPubkey = configService.activeAccountHexPubkey
        let visible = Set(blockFilter.pubkeys(Array(postCounts.keys)))
        return postCounts
            .filter { $0.key != ownPubkey && visible.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .compactMap { pubkey, _ in
                guard let profile = nostrService.profiles[pubkey],
                      profile.name != nil || profile.displayName != nil else { return nil }
                return (pubkey, profile)
            }
    }

    /// Recomputes the empty-state discovery lists (trending hashtags + suggested
    /// profiles) into cached state. The feed streams events continuously, so these
    /// are throttled to avoid the empty state reshuffling on every published change.
    func refreshDiscovery(force: Bool = false) {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastDiscoveryRefresh) >= 5 else { return }
        lastDiscoveryRefresh = now
        cachedTrending = computeTrendingHashtags()
        cachedSuggested = computeSuggestedProfiles()
        refreshRecommendations()
    }

    /// The active account's blocks, applied to everything a search returns.
    var blockFilter: SearchBlockFilter {
        SearchBlockFilter(blocked: configService.activeAccountBlockedHexPubkeys)
    }

    func visibleNotes(_ notes: [FeedNote], _ filter: SearchBlockFilter) -> [FeedNote] {
        filter.notes(notes) { note, blocked in
            FeedFilterEngine.involvesBlocked(note, blocked: blocked,
                                             authorOf: { self.feedService.findNote(id: $0)?.pubkey })
        }
    }

    /// Opens a note in the split pane's detail column when there is one, and
    /// falls back to the sheet everywhere else.
    func openNote(_ note: FeedNote) {
        if let noteDetailSelection {
            noteDetailSelection.select(note)
        } else {
            showingNoteDetail = note
        }
    }

    /// Runs the search for whatever is in the field right now, cancelling the debounce
    /// task so Return doesn't race a second search behind it.
    func searchNow() {
        searchDebounceTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSearch(query: searchQuery)
        saveRecentSearch(searchQuery)
    }

    func clearSearch() {
        searchDebounceTask?.cancel()
        searchQuery = ""
        resultTypeFilter = .all
        searchResults = .empty
        pendingDirectNoteId = nil
        isSearching = false
        globalSources = []
        globalSnapshot = nil
        globalFinished = true
        nostrService.cancelGlobalSearch()
    }

    func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A new query supersedes whatever Global search was streaming.
        nostrService.cancelGlobalSearch()
        globalSources = []
        globalSnapshot = nil
        globalFinished = true
        guard !trimmed.isEmpty else {
            searchResults = .empty
            pendingDirectNoteId = nil
            return
        }

        // A profile link (nostrvault.app/p/…, nostr:npub…) pasted: open the
        // profile it names, and list it as a bare npub would be.
        if case .profile(let id) = NostrURI(string: trimmed),
           let hexKey = QuoteReference.profilePubkey(fromBech32: id) {
            showDirectProfile(hexKey)
            #if os(iOS)
            // The profile covers the field: put the keyboard away with it.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            showingProfile = hexKey
            return
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let eventId = decodeNostrNoteId(trimmed) {
                if let note = feedService.findNote(id: eventId) {
                    openNote(note)
                } else {
                    pendingDirectNoteId = eventId
                    isSearching = true
                    searchResults = .empty
                    feedService.fetchMissingNote(id: eventId)
                }
            }
            return
        }

        // Decode npub to hex pubkey for direct profile lookup
        if lower.hasPrefix("npub1"),
           let decoded = Bech32.decode(trimmed),
           decoded.hrp == "npub" {
            showDirectProfile(decoded.hexString)
            return
        }

        pendingDirectNoteId = nil

        // Require at least 2 characters for general search
        let trimmedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard trimmedQuery.count >= 2 else {
            searchResults = .empty
            isSearching = false
            return
        }

        // Global search: this device's store, the Mac relay and the NIP-50
        // search relays at once, streamed as each answers.
        isSearching = true
        globalFinished = false
        let requestedQuery = trimmed
        globalSearchLifetime.session = nostrService.startGlobalSearch(query: trimmed,
                                       deviceRelay: feedService.localRelayURL,
                                       follows: feedService.followedPubkeys) { snapshot in
            // Ignore stale updates (user changed query).
            guard self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }
            self.globalSnapshot = snapshot
            self.searchResults = self.filteredResults(from: snapshot, query: trimmedQuery)
            self.globalSources = snapshot.sources
            self.globalFinished = snapshot.isFinished
            self.isSearching = false
        }
    }

    /// One key, looked up directly: its profile as the only result.
    private func showDirectProfile(_ hexKey: String) {
        var results = SearchResults()
        results.users[hexKey] = nostrService.profiles[hexKey] ?? FeedProfile(pubkey: hexKey)
        searchResults = results
        isSearching = false
        pendingDirectNoteId = nil
    }

    /// Re-applies the who/when filter to the answer already on hand. Nothing
    /// is re-fetched: the stream keeps every match and the filter picks.
    func applySearchFilter() {
        guard let snapshot = globalSnapshot else { return }
        let trimmedQuery = searchQuery.lowercased().trimmingCharacters(in: .whitespaces)
        searchResults = filteredResults(from: snapshot, query: trimmedQuery)
    }

    /// Blocks, then the who/when scope, then the per-type lists. Hashtags and
    /// links come from the notes that survived, so they follow the filter too.
    func filteredResults(from snapshot: GlobalSearchSnapshot, query trimmedQuery: String) -> SearchResults {
        let filter = blockFilter
        let scope = searchFilter
        let own = configService.activeAccountHexPubkey
        let follows = Set(feedService.followedPubkeys)
        let profiles = filter.profiles(snapshot.profiles, pubkey: \.pubkey)
            .filter { scope.allowsAuthor($0.pubkey, own: own, follows: follows) }
        let now = Date()
        let notes = visibleNotes(snapshot.notes, filter)
            .filter { scope.allowsAuthor($0.pubkey, own: own, follows: follows) && scope.allowsDate($0.createdAt, now: now) }

        var results = SearchResults()
        for profile in profiles {
            results.users[profile.pubkey] = profile
        }
        results.userOrder = profiles.map(\.pubkey)
        // Already ranked own → follows → everyone, newest first in each.
        results.notes = Array(notes.prefix(100))

        var foundHashtags = Set<String>()
        for note in notes {
            for tag in extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                foundHashtags.insert(tag)
            }
        }
        results.hashtags = Array(foundHashtags).sorted()

        results.links = extractURLs(from: results.notes)
        return results
    }

    private func extractHashtags(from text: String) -> [String] {
        let pattern = "#\\w+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range]).dropFirst().lowercased()
        }
    }

    /// Links found in the notes that matched. The list is keyed by URL in the
    /// UI, so the same URL is kept once — two notes sharing a link used to be
    /// two rows with the same SwiftUI identity.
    private func extractURLs(from notes: [FeedNote]) -> [SearchLink] {
        var links: [SearchLink] = []
        var seen = Set<String>()
        let urlPattern = "https?://[^\\s]+"

        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return [] }

        for note in notes {
            let matches = regex.matches(in: note.content, range: NSRange(note.content.startIndex..., in: note.content))
            for match in matches {
                guard let range = Range(match.range, in: note.content) else { continue }
                let url = String(note.content[range])
                guard seen.insert(url).inserted else { continue }
                links.append(SearchLink(url: url, title: url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), noteId: note.id))
            }
        }

        return links
    }
}
