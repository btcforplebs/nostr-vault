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
    }

    /// The active account's blocks, applied to everything a search returns.
    private var blockFilter: SearchBlockFilter {
        SearchBlockFilter(blocked: configService.activeAccountBlockedHexPubkeys)
    }

    private func visibleNotes(_ notes: [FeedNote], _ filter: SearchBlockFilter) -> [FeedNote] {
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

    /// Re-run the current query, e.g. after switching between relay/global modes.
    func rerunSearch() {
        nostrService.cancelGlobalSearch()
        nostrService.cancelLocalRelaySearch()
        globalSources = []
        globalFinished = true
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            isSearching = false
            return
        }
        performSearch(query: searchQuery)
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
        globalFinished = true
        nostrService.cancelGlobalSearch()
        nostrService.cancelLocalRelaySearch()
    }

    func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A new query supersedes whatever Global search was streaming.
        nostrService.cancelGlobalSearch()
        globalSources = []
        globalFinished = true
        guard !trimmed.isEmpty else {
            searchResults = .empty
            pendingDirectNoteId = nil
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
            let hexKey = decoded.hexString
            var results = SearchResults()
            if let profile = nostrService.profiles[hexKey] {
                results.users[hexKey] = profile
            } else {
                results.users[hexKey] = FeedProfile(pubkey: hexKey)
            }
            searchResults = results
            isSearching = false
            pendingDirectNoteId = nil
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
        if searchMode == .global {
            isSearching = true
            globalFinished = false
            let requestedQuery = trimmed
            globalSearchLifetime.session = nostrService.startGlobalSearch(query: trimmed,
                                           deviceRelay: feedService.localRelayURL,
                                           follows: feedService.followedPubkeys) { snapshot in
                // Ignore stale updates (user changed query or switched mode).
                guard self.searchMode == .global,
                      self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }

                let filter = self.blockFilter
                let profiles = filter.profiles(snapshot.profiles, pubkey: \.pubkey)
                let notes = self.visibleNotes(snapshot.notes, filter)

                var results = SearchResults()
                for profile in profiles {
                    results.users[profile.pubkey] = profile
                }
                results.userOrder = profiles.map(\.pubkey)
                // Already ranked own → follows → everyone, newest first in each.
                results.notes = Array(notes.prefix(100))

                var foundHashtags = Set<String>()
                for note in notes {
                    for tag in self.extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
                results.hashtags = Array(foundHashtags).sorted()

                results.links = self.extractURLs(from: results.notes)

                self.searchResults = results
                self.globalSources = snapshot.sources
                self.globalFinished = snapshot.isFinished
                self.isSearching = false
            }
            return
        }

        // Relay search: query the local relay's full stored dataset directly,
        // not just whatever the feed subscription has already loaded.
        isSearching = true

        guard let relayURL = feedService.localRelayURL else {
            // Relay not up yet (e.g. still booting) — fall back to whatever's
            // already in memory rather than showing nothing.
            performInMemoryRelaySearch(trimmedQuery: trimmedQuery)
            return
        }

        let requestedQuery = trimmed
        nostrService.localRelaySearch(query: trimmed, relayURL: relayURL) { localResults in
            // Ignore stale completions (user changed query or switched mode).
            guard self.searchMode == .relay,
                  self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }

            let filter = self.blockFilter
            let profiles = filter.profiles(localResults.profiles, pubkey: \.pubkey)
            let notes = self.visibleNotes(localResults.notes, filter)

            var results = SearchResults()
            for profile in profiles {
                results.users[profile.pubkey] = profile
            }
            results.notes = Array(notes.prefix(20))

            var foundHashtags = Set<String>()
            for note in notes {
                for tag in self.extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                    foundHashtags.insert(tag)
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            // Links are what the matching notes link to, so a note that matches
            // on its text contributes its links even when the query is nowhere
            // in the URL (Logen, 2026-09-09).
            results.links = self.extractURLs(from: notes)

            self.searchResults = results
            self.isSearching = false
        }
    }

    /// Fallback used only when the local relay isn't reachable yet: filters
    /// whatever's already loaded into the live feed/profile cache.
    private func performInMemoryRelaySearch(trimmedQuery: String) {
        let filter = blockFilter
        let visibleKeys = Set(filter.pubkeys(Array(nostrService.profiles.keys)))
        let localProfiles = nostrService.profiles.filter { visibleKeys.contains($0.key) }
        let localNotes = visibleNotes(feedService.notes, filter)

        // Same matching rules as the relay walk, so the fallback cannot drift
        // away from the real path.
        guard let matcher = LocalSearchMatcher(query: trimmedQuery) else {
            searchResults = .empty
            isSearching = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var results = SearchResults()

            for (pubkey, profile) in localProfiles {
                if matcher.matchesProfile(displayName: profile.displayName,
                                          name: profile.name,
                                          about: profile.about,
                                          nip05: profile.nip05,
                                          pubkey: pubkey) {
                    results.users[pubkey] = profile
                }
            }

            let relevantNotes = localNotes
                .filter { matcher.matchesNote(content: $0.content) }
                .sorted { $0.createdAt > $1.createdAt }
            results.notes = relevantNotes.prefix(20).map { $0 }

            var foundHashtags = Set<String>()
            for note in relevantNotes {
                let hashtags = extractHashtags(from: note.content)
                for tag in hashtags {
                    if tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            results.links = extractURLs(from: relevantNotes)

            DispatchQueue.main.async {
                self.searchResults = results
                self.isSearching = false
            }
        }
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
