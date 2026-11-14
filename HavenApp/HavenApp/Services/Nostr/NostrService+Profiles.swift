import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Records that `pubkey`'s profile changed and schedules a coalesced flush
    /// of `profileUpdates`. Must be called on the main thread (all call sites
    /// already are, inside `DispatchQueue.main.async`).
    func noteProfileUpdated(_ pubkey: String) {
        pendingProfileUpdates.insert(pubkey)
        guard !profileUpdateFlushScheduled else { return }
        profileUpdateFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.profileUpdateFlushScheduled = false
            guard !self.pendingProfileUpdates.isEmpty else { return }
            let batch = self.pendingProfileUpdates
            self.pendingProfileUpdates.removeAll(keepingCapacity: true)
            self.profileUpdateGeneration &+= 1
            self.profileUpdates = ProfileUpdateSignal(generation: self.profileUpdateGeneration, pubkeys: batch)
        }
    }

    /// Queues a parsed kind 0 and writes the batch to `profiles` shortly
    /// after: one redraw of every watching screen per batch, not one per
    /// profile. Must be called on the main thread.
    func queueProfileWrite(_ profile: FeedProfile) {
        profileWrites.add(profile)
        guard !profileWriteFlushScheduled else { return }
        profileWriteFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.profileWriteFlushScheduled = false
            guard !self.profileWrites.isEmpty else { return }
            // Still in flight until stored, so nothing asks for it again meanwhile.
            self.profilesInFlight.subtract(self.profileWrites.pending.keys)
            let written = self.profileWrites.flush(into: &self.profiles)
            guard !written.isEmpty else { return }
            self.saveProfilesThrottled()
            self.eventUpdateSubject.send()
            for pubkey in written { self.noteProfileUpdated(pubkey) }
        }
    }

    func updateOwnerHex() {
        let npub = ConfigService.shared.config.ownerNpub
        if let hex = Bech32.decode(npub)?.hexString {
            self.ownerHexPubkey = hex
            #if DEBUG
            print("NostrService: Owner Hex Pubkey: \(hex)")
            #endif
        } else {
            self.ownerHexPubkey = ""
        }
    }

    /// Pre-fetches profiles for the owner + all whitelisted npubs so avatars
    /// are ready when the account switcher is opened.
    func prefetchWhitelistedProfiles() {
        let allNpubs = ConfigService.shared.allAccountNpubs
        let hexPubkeys = allNpubs.compactMap { npub -> String? in
            let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(trimmed)?.hexString
        }
        fetchMissingProfiles(for: hexPubkeys)
    }

    func setupMetadataFlusher() {
        profileFlushCancellable = Timer.publish(every: RelayRequestBudget.profileFlushInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.flushMetadataRequests()
            }
    }

    private func flushMetadataRequests() {
        // Nothing left to fetch: stop ticking. `fetchMissingProfiles` starts
        // the timer again on the next enqueue. It used to run twice a second
        // for the life of the app.
        guard !profileFetchQueue.isEmpty else {
            profileFlushCancellable?.cancel()
            profileFlushCancellable = nil
            return
        }
        let pubkeys = Array(profileFetchQueue)
        profileFetchQueue.removeAll()

        // Looking things up is reading: the Read relays
        var relays = ConfigService.shared.config.readRelays
        relays += Self.profileIndexRelays

        // A lookup must be able to run again once it is over: one that found
        // nothing, or one that found the profile unchanged (a kind 0 only
        // clears its key when something changed), would otherwise block every
        // later lookup of that person, forced or not, until the app restarts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            for pubkey in pubkeys {
                self.profilesInFlight.remove(pubkey)
            }
        }

        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Read relays")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }
        for url in uniqueRelays {
            sendProfileRequest(pubkeys, to: url)
        }
    }

    /// Lookup sockets are shared (`LookupSocketPool`) and close themselves
    /// when idle; this drops them all at once (background).
    func closeProfileLookupSockets() {
        LookupSocketPool.shared.closeAll()
    }

    func loadProfiles() {
        self.profiles = ProfileRepository.loadProfiles()
        self.relayLists = ProfileRepository.loadRelayLists()
        self.outboxRelays = ProfileRepository.loadOutboxRelays()
        self.serverLists = ProfileRepository.loadServerLists()
        self.dmRelayLists = ProfileRepository.loadDMRelayLists()
        #if DEBUG
        print("NostrService: Loaded \(profiles.count) profiles, \(relayLists.count) relay lists, \(outboxRelays.count) outbox, \(serverLists.count) servers, \(dmRelayLists.count) DM relays from cache")
        #endif
    }

    func saveProfilesThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProfileSave) > profileSaveThrottle {
            lastProfileSave = now
            // The accounts' own profiles and the active account's follows
            // stay on disk whatever the cap drops.
            let keep = ConfigService.shared.allAccountHexes.union(FeedService.shared.followedPubkeys.map { $0.lowercased() })
            ProfileRepository.saveProfiles(profiles, keep: keep)
            ProfileRepository.saveRelayLists(relayLists)
            ProfileRepository.saveOutboxRelays(outboxRelays)
            ProfileRepository.saveDMRelayLists(dmRelayLists)
            ProfileRepository.saveServerLists(serverLists)
        }
    }

    func fetchMissingProfiles(for pubkeys: [String], force: Bool = false) {
        let missing = pubkeys.filter { (force || profiles[$0] == nil) && !profilesInFlight.contains($0) }
        guard !missing.isEmpty else { return }

        for pubkey in missing {
            profilesInFlight.insert(pubkey)
            profileFetchQueue.insert(pubkey)
        }

        if profileFlushCancellable == nil && !profileFetchPaused {
            setupMetadataFlusher()
        }
    }


    /// One REQ per `ProfileLookupBatch.authorsPerRequest` authors, on
    /// `url`'s shared lookup socket. The socket stays open for the next batch
    /// and for the other lookups: a new connection per tick was most of what
    /// relay.damus.io counted against us (2026-10-31).
    private func sendProfileRequest(_ pubkeys: [String], to url: URL) {
        let key = url.absoluteString
        for chunk in ProfileLookupBatch.chunks(pubkeys) {
            let filter: [String: Any] = [
                "kinds": [0, 10002, 10050, 10000, 10063],
                "authors": chunk
            ]
            LookupSocketPool.shared.query(
                url: url, subId: "meta-\(UUID().uuidString.prefix(8))", filters: [filter],
                timeout: RelayRequestBudget.profileSubscriptionSeconds,
                onMessage: { [weak self] message in
                    self?.processingQueue.async { self?.processMessage(message, from: key) }
                })
        }
    }
}
