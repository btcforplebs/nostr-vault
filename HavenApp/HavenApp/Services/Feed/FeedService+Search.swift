import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Search

    /// Queries the local relay with the current feed mode's filter set and
    /// filters returned events client-side by content text matching.
    func performSearch(query: String) {
        guard let relayURL = localRelayURL else {
            // Fall back to in-memory search if relay unavailable
            searchResults = filteredNotes.filter {
                $0.content.localizedCaseInsensitiveContains(query)
            }
            isSearching = false
            return
        }

        // The authors this mode searches, decided before anything connects.
        //
        // An author-scoped mode with an empty author set must not fall through
        // to an unrestricted filter: dropping the `authors` key turns "search
        // your follows" into "search the whole relay" while the UI still says
        // you are in Following or Discovery. No authors means no results.
        //
        // Articles follows its own scope: follows in Following, anyone in Global.
        let searchAuthors: [String]?
        switch feedMode {
        case .following: searchAuthors = followedPubkeys
        case .articles: searchAuthors = articlesFeedMode == .following ? followedPubkeys : nil
        case .polls: searchAuthors = pollsFeedMode == .following ? followedPubkeys : nil
        case .discovery: searchAuthors = extendedNetworkPubkeys
        case .global, .popular, .media, .recipes, .marketplace, .live, .reels, .music, .hashtags: searchAuthors = nil
        }
        if let searchAuthors, searchAuthors.isEmpty {
            searchCancellable?.cancel()
            searchClient?.disconnect()
            searchClient = nil
            searchResults = []
            isSearching = false
            return
        }

        // Cancel any previous search subscription
        searchCancellable?.cancel()
        searchClient?.disconnect()
        isSearching = true

        let client = WebSocketClient()
        client.isTemporary = true
        searchClient = client

        // Build filter matching current feed mode
        var filter: [String: Any] = [
            "kinds": [1, 6, 30023, NIP88Poll.kind],
            "limit": 2000
        ]
        if let searchAuthors {
            filter["authors"] = searchAuthors
        }

        let subId = "search-\(UUID().uuidString.prefix(8))"
        var collected: [FeedNote] = []
        var seenSearchIds = Set<String>()
        let lowerQuery = query.lowercased()

        searchCancellable = client.messageSubject
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] (msg: String) in
                guard let data = msg.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = json[0] as? String else { return }

                if type == "EOSE" {
                    let results = collected.sorted {
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.id > $1.id
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.searchResults = results
                        self.isSearching = false
                        self.searchClient?.disconnect()
                        self.searchClient = nil
                        self.searchCancellable = nil
                    }
                    return
                }

                guard type == "EVENT", json.count >= 3,
                      let ev = json[2] as? [String: Any],
                      let id        = ev["id"]         as? String,
                      let pubkey    = ev["pubkey"]      as? String,
                      let content   = ev["content"]     as? String,
                      let createdAt = ev["created_at"]  as? Int64,
                      let kind      = ev["kind"]        as? Int,
                      let tags      = ev["tags"]        as? [[String]]
                else { return }

                guard !seenSearchIds.contains(id) else { return }
                seenSearchIds.insert(id)

                let note = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind,
                    repostedBy: kind == 6 ? pubkey : nil
                )

                // Client-side content filter
                if note.content.lowercased().contains(lowerQuery) {
                    collected.append(note)
                }
            }

        client.connect(url: relayURL)

        // Send REQ after a brief delay to ensure connection is established
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let req = ["REQ", subId, filter] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: req),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }

        // Timeout: if EOSE never arrives, stop after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isSearching else { return }
            let results = collected.sorted { $0.createdAt > $1.createdAt }
            self.searchResults = results
            self.isSearching = false
            self.searchClient?.disconnect()
            self.searchClient = nil
            self.searchCancellable = nil
        }
    }

    func clearSearch() {
        searchDebounceWork?.cancel()
        searchCancellable?.cancel()
        searchClient?.disconnect()
        searchClient = nil
        searchCancellable = nil
        searchQuery = ""
        searchResults = []
        isSearchActive = false
        isSearching = false
    }
}
