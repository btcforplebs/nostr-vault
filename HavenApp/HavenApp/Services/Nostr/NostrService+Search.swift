import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Global search: this device's store, the Mac relay (iOS, when set) and
    /// every configured NIP-50 search relay, all at once. `onUpdate` runs on
    /// the main queue each time a source answers — results stream in, ranked
    /// own posts → follows → everyone — and a last time with `isFinished`.
    /// Any prior Global search is cancelled first.
    ///
    /// - Parameter deviceRelay: the embedded relay's URL, or nil if it is not
    ///   running. On macOS this IS the Mac relay, so the Mac is not asked twice.
    /// - Returns: the running session (nil for a query too short to run), so
    ///   the caller can stop it when it goes away.
    @discardableResult
    func startGlobalSearch(query: String,
                           deviceRelay: URL?,
                           follows: [String],
                           onUpdate: @escaping (GlobalSearchSnapshot) -> Void) -> GlobalSearchSession? {
        cancelGlobalSearch()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            var done = GlobalSearchSnapshot()
            done.isFinished = true
            onUpdate(done)
            return nil
        }

        var request = GlobalSearchSession.Request(
            query: trimmed,
            searchRelays: SearchRelaySettings.relays.compactMap { URL(string: $0) },
            deviceRelay: deviceRelay)
        // `macRelayURL(config:)` is "" on macOS: there the Mac relay is the
        // device relay above.
        let mac = RelayConfiguration.macRelayURL(config: ConfigService.shared.config)
        if !mac.isEmpty, let macURL = URL(string: mac), macURL.host != deviceRelay?.host {
            request.macRelay = macURL
        }
        request.cachedProfiles = profiles
        request.own = Set([activeHexPubkey, ownerHexPubkey].filter { !$0.isEmpty })
        request.follows = Set(follows)
        request.wot = FeedService.shared.webOfTrustForRanking

        let session = GlobalSearchSession(request: request) { [weak self] snapshot in
            guard let self = self else { return }
            // Merge discovered profiles into the shared cache so avatars/names render.
            for profile in snapshot.profiles where self.profiles[profile.pubkey] == nil {
                self.profiles[profile.pubkey] = profile
            }
            onUpdate(snapshot)
        }
        globalSearchSession = session
        session.start()
        return session
    }

    /// NIP-50 lookup against the search relays only. Used by @-mention lookup:
    /// discovered profiles are merged into `profiles`, and `completion` runs on
    /// the main queue each time a relay answers (so a fast relay's profiles show
    /// without waiting for a slow one) — callers must tolerate repeat calls.
    /// Does not disturb a Global search running in the Search tab.
    func globalSearch(query: String, completion: @escaping (GlobalSearchResults) -> Void) {
        mentionSearchSession?.cancel()
        mentionSearchSession = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let relays = SearchRelaySettings.relays.compactMap { URL(string: $0) }
        guard trimmed.count >= 2, !relays.isEmpty else {
            completion(GlobalSearchResults())
            return
        }
        var request = GlobalSearchSession.Request(query: trimmed, searchRelays: relays, deviceRelay: nil)
        request.includeDevice = false
        let session = GlobalSearchSession(request: request) { [weak self] snapshot in
            guard let self = self else { return }
            for profile in snapshot.profiles where self.profiles[profile.pubkey] == nil {
                self.profiles[profile.pubkey] = profile
            }
            if snapshot.isFinished { self.mentionSearchSession = nil }
            completion(GlobalSearchResults(profiles: snapshot.profiles, notes: snapshot.notes,
                                           isFinished: snapshot.isFinished))
        }
        mentionSearchSession = session
        session.start()
    }

    /// Stops the Search tab's Global search. No update arrives after this.
    func cancelGlobalSearch() {
        globalSearchSession?.cancel()
        globalSearchSession = nil
    }

    /// Searches everything the embedded relay has stored, not just whatever the
    /// feed subscription has already loaded into memory.
    ///
    /// Three things this has to get right:
    ///
    /// 1. **Every route.** haven serves several stores off one port and they
    ///    hold different things: `/` is the outbox and only ever accepts events
    ///    the owner signed (`MustBeWhitelistedToPost`), the follows' notes live
    ///    on `/feed`, and notes that tag the owner live on `/inbox`. Searching
    ///    `/` alone means searching your own posts.
    /// 2. **Paging.** The LMDB backend honours a limit only up to 1500 and
    ///    quietly drops anything larger to 375 — see `LocalRelaySearchPlan`. A
    ///    single REQ cannot cover the store, so each route/kind is paged with an
    ///    `until` cursor until it runs dry.
    /// 3. **Finishing on EOSE.** The relay is on-box and answers in
    ///    milliseconds; a fixed timer would make every search take that long.
    ///    The timeout below is a fallback for a socket that never replies.
    ///
    /// The relay's backends no-op any filter with `search` set, so matching is
    /// done client-side; profiles already in the in-memory cache are matched too,
    /// because no local store holds anyone else's kind 0. A note matches on its
    /// text OR on its author's profile, so searching a person's name finds what
    /// they wrote and not just their profile card.
    func localRelaySearch(query: String, relayURL: URL, completion: @escaping (GlobalSearchResults) -> Void) {
        cancelLocalRelaySearch()

        guard let matcher = LocalSearchMatcher(query: query) else {
            completion(GlobalSearchResults())
            return
        }

        let base = relayURL.absoluteString
        let routes = [base, base + "/feed", base + "/inbox"].compactMap { URL(string: $0) }

        let session = LocalRelaySearchSession(matcher: matcher, routes: routes) { [weak self] results in
            guard let self = self else { return }
            DispatchQueue.main.async {
                for profile in results.profiles where self.profiles[profile.pubkey] == nil {
                    self.profiles[profile.pubkey] = profile
                }
                completion(results)
            }
        }
        localSearchSession = session
        session.addCachedProfiles(profiles)
        session.start()
    }

    /// Tears down any in-flight local relay search connections.
    func cancelLocalRelaySearch() {
        localSearchSession?.cancel()
        localSearchSession = nil
    }
}
