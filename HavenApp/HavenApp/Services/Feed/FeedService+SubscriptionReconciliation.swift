import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Subscription Reconciliation

    /// True for feed modes whose primary subscription filters by an author set
    /// (Following / Media-Following / Discovery). Global, Popular and the inbox
    /// sub do not, so their subscriptions never drift on the follow set.
    private var isAuthorFilteredMode: Bool {
        switch feedMode {
        case .following, .discovery: return true
        case .media: return mediaFeedMode == .following
        case .articles: return articlesFeedMode == .following
        case .polls: return pollsFeedMode == .following
        case .global, .popular, .recipes, .marketplace, .live, .reels, .music, .hashtags: return false
        }
    }

    /// Kinds the primary feed subscription asks for. Articles is a long-form
    /// feed, so narrowing the REQ stops a page of results from being almost
    /// entirely kind-1 notes the mode is about to discard.
    var primaryFeedKinds: [Int] {
        switch feedMode {
        case .articles: return [30023]
        case .polls: return [NIP88Poll.kind]
        default: return [1, 6, 30023, NIP10Thread.commentKind, NIP88Poll.kind]
        }
    }

    /// True for the modes whose primary subscription is `authors: followedPubkeys`.
    /// Articles (Following) is Following restricted to kind 30023, so it shares
    /// every follow-set guard: the empty-follow-set short circuit, pagination,
    /// and the dead-`authors:[]` REQ guard. Articles (Global) is global-like.
    var isFollowSetMode: Bool {
        feedMode == .following || (feedMode == .articles && articlesFeedMode == .following)
            || (feedMode == .polls && pollsFeedMode == .following)
    }

    /// The authoritative author set the current mode's primary subscription should
    /// carry. Empty means "no valid primary sub" for author-filtered modes.
    private func desiredPrimaryAuthorsForMode() -> [String] {
        switch feedMode {
        case .following: return followedPubkeys
        case .articles: return articlesFeedMode == .following ? followedPubkeys : []
        case .polls: return pollsFeedMode == .following ? followedPubkeys : []
        case .media: return mediaFeedMode == .following ? followedPubkeys : []
        case .discovery: return extendedNetworkPubkeys
        case .global, .popular, .recipes, .marketplace, .live, .reels, .music, .hashtags: return []
        }
    }

    /// Desired authors for a specific relay key. Returns `nil` for relays that
    /// carry no author filter (the local inbox queries by `#p`; global/popular
    /// have no authors), so the drift check skips them.
    private func desiredPrimaryAuthors(forRelayKey key: String) -> [String]? {
        if key == localInboxURL?.absoluteString { return nil }
        guard isAuthorFilteredMode else { return nil }
        if feedMode != .discovery, let planned = outboxPlan[key] { return planned }
        return desiredPrimaryAuthorsForMode()
    }

    /// Make the live relay subscriptions match the current authoritative inputs
    /// (relayReady, feedMode, follow set, isPaused). Idempotent and safe to call
    /// from anywhere any number of times — never tears down the rendered feed,
    /// only connects missing relays and re-sends REQs whose author set has drifted.
    func reconcileFeedSubscriptions() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        guard !isPaused else { return }
        guard feedMode != .popular else { return }   // popular has no relay subs
        guard feedMode != .reels else { return }     // ReelsFeedService owns its own
        // Recipes, Marketplace and Live run their own services and Music has
        // no relay feed. Reconciling here opened an author-less kind-1 REQ
        // underneath them, so the hidden note pipeline filled with strangers'
        // posts and a "New Posts" pill appeared over the grid.
        guard ![.recipes, .marketplace, .live, .music, .hashtags].contains(feedMode) else { return }

        // Author-filtered mode with no follows yet → no valid primary sub. Don't
        // send a dead authors:[] REQ; instead self-heal by (re)fetching contacts
        // if the relay is ready and we're not already loading. When follows land,
        // the contact-load completion calls back into reconcile.
        if isAuthorFilteredMode && desiredPrimaryAuthorsForMode().isEmpty {
            if RelayProcessManager.shared.isRunning,
               !RelayProcessManager.shared.isBooting,
               !isLoadingContacts, !isSyncing {
                loadContactList { [weak self] in self?.reconcileFeedSubscriptions() }
            }
            return
        }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty { return }

        ensureRelaySetConnected()
        resubscribePrimaryIfNeeded()
    }

    /// Connect the relays that should be part of the current subscription but
    /// aren't yet (notably the local relay/inbox once boot completes). Existing
    /// connections are left untouched. Absorbs the old `addLocalRelayIfReady`.
    private func ensureRelaySetConnected() {
        if isGlobalLikeMode {
            loadWotPubkeys()
        }

        refreshOutboxPlan()
        let desiredURLs = feedRelayURLs()

        // An outbox relay the plan dropped (its follows were picked up by
        // another, or it died) would otherwise stay subscribed — and with no
        // plan entry it would be re-sent the whole follow list.
        let desiredKeys = Set(desiredURLs.map(\.absoluteString))
        for key in feedClients.keys where !key.hasPrefix("page-") && !desiredKeys.contains(key) {
            feedClients[key]?.disconnect()
            feedClients.removeValue(forKey: key)
            subscribedAuthorsByRelay[key] = nil
        }

        let missing = desiredURLs.filter { feedClients[$0.absoluteString] == nil }
        guard !missing.isEmpty else { return }

        let totalRelays = feedClients.count + missing.count
        #if DEBUG
        print("FeedService: reconcile connecting \(missing.count) missing relay(s) (total \(totalRelays))")
        #endif
        for url in missing {
            connectFeedRelay(url: url, totalRelays: totalRelays)
        }
    }

    /// Re-issue the primary REQ to any connected feed client whose live author set
    /// differs from the desired one. Reuses the same `subId` so the relay replaces
    /// the prior subscription rather than opening a duplicate stream. `.connecting`
    /// clients are handled by their own connect sink (which reads the live follow
    /// set). Does NOT touch `isLoadingFeed`/`eoseCount` — a background resubscribe
    /// must not re-show the full-screen spinner.
    func resubscribePrimaryIfNeeded() {
        for (key, client) in feedClients {
            // Older-page clients are one-shot; re-sending them a primary REQ
            // added stray EOSEs to whatever load was running.
            guard !key.hasPrefix("page-"), client.connectionState == .connected else { continue }
            // nil-author relays (inbox/global/popular) never drift on follows.
            guard let desired = desiredPrimaryAuthors(forRelayKey: key) else { continue }
            if let current = subscribedAuthorsByRelay[key], Set(current) == Set(desired) {
                continue   // already in sync
            }
            sendPrimaryFeedSubscription(client: client, label: key)
        }
    }

    /// Background refresh against an already-rendered snapshot. Re-subscribes
    /// to relays so newer notes stream in on top of the cached feed, and
    /// kicks off a contact-list re-fetch in parallel so a stale follow set
    /// gets updated without blocking the visible feed.
    func topUpFromRelays() {
        let isGlobalLike = isGlobalLikeMode
        guard !followedPubkeys.isEmpty || isGlobalLike else {
            // Snapshot had no follows — fall back to the cold-start flow.
            // An account switch sets isLoadingContacts before calling here, and
            // refresh() returns early while it is set, so without clearing it
            // this fallback did nothing and the feed stayed empty.
            isLoadingContacts = false
            refresh()
            return
        }

        isSyncing = true
        shouldScrollToTopOnLoad = false
        newSinceLastView = Date()

        // 1. Subscribe to relays immediately using the cached follow set.
        if isGlobalLike {
            loadWotPubkeys()
        }
        if isGlobalLike || !followedPubkeys.isEmpty {
            subscribeToAllRelays()
        }

        // 2. Re-fetch the contact list in the background. When it lands,
        // newly-followed authors are picked up by the running subscription on
        // the next refresh cycle (and `publishContactList` writes the diff).
        // We don't block on it.
        loadContactList { [weak self] in
            guard let self = self else { return }
            self.isSyncing = false
        }
    }
}
