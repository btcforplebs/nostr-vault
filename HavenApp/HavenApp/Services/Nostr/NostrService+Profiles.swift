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
        profileFlushCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
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

        // A lookup that found nothing must be able to run again, or a profile
        // missed once stays a bare key until the app restarts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            for pubkey in pubkeys where self.profiles[pubkey] == nil {
                self.profilesInFlight.remove(pubkey)
            }
        }

        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Read relays")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true

            let urlString = url.absoluteString
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self else { return }
                    if state == .connected {
                        self.sendProfileRequest(to: client, pubkeys: pubkeys)
                        // Disconnect after results come in (or reasonable timeout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
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
            ProfileRepository.saveProfiles(profiles)
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


    private func sendProfileRequest(to client: WebSocketClient, pubkeys: [String]) {
        let subscriptionId = "meta-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = [
            "kinds": [0, 10002, 10050, 10000, 10063],
            "authors": pubkeys
        ]

        let req = ["REQ", subscriptionId, filter] as [Any]

        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
    }
}
