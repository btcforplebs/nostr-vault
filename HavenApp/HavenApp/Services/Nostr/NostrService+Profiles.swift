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
        guard !profileFetchQueue.isEmpty else { return }
        let pubkeys = Array(profileFetchQueue)
        profileFetchQueue.removeAll()

        // Looking things up is reading: the Read relays
        var relays = ConfigService.shared.config.readRelays
        relays += Self.profileIndexRelays
        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(uniqueRelays.count) Read relays")
        #endif

        let pool = Self.profileLookups
        let batch = pool.startBatch(pubkeys: pubkeys)
        var requests: [(url: URL, subId: String, authors: [String])] = []
        for start in stride(from: 0, to: pubkeys.count, by: ProfileLookupPool.authorsPerReq) {
            let chunk = Array(pubkeys[start..<min(start + ProfileLookupPool.authorsPerReq, pubkeys.count)])
            for url in uniqueRelays {
                requests.append((url, "meta-\(UUID().uuidString.prefix(8))", chunk))
            }
        }
        // All tracked before any is sent, so a relay skipped at once can't
        // end the batch while the others are still to be asked.
        for r in requests { pool.track(subId: r.subId, relay: r.url.absoluteString, batch: batch) }
        for r in requests { sendProfileRequest(to: r.url, subId: r.subId, pubkeys: r.authors) }
        // A relay that never answers (or was skipped while cooling down)
        // must not hold the batch open: give up on it after the deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + ProfileLookupPool.batchDeadline) { [weak self] in
            self?.finishProfileBatch(batch)
        }
    }

    /// The pubkeys a batch asked for that no relay had are backed off, so
    /// the globe or a feed asking again within minutes stays quiet.
    private func finishProfileBatch(_ batch: Int) {
        guard let (pubkeys, unanswered, anyAnswered) = Self.profileLookups.endBatch(batch) else { return }
        // Release what a slow relay still holds open for this batch.
        for (subId, relay) in unanswered {
            guard let client = Self.profileLookups.sockets[relay]?.client,
                  client.connectionState == .connected,
                  let data = try? JSONSerialization.data(withJSONObject: ["CLOSE", subId] as [Any]),
                  let close = String(data: data, encoding: .utf8) else { continue }
            client.send(text: close)
        }
        let now = Date()
        for pubkey in pubkeys where profiles[pubkey] == nil {
            profilesInFlight.remove(pubkey)
            // Only a real "not here" counts as a miss, not every relay down.
            if anyAnswered { Self.profileLookups.missedAt[pubkey] = now }
        }
    }

    /// Sends one REQ on the long-lived lookup socket for `url`, opening it
    /// if needed. The REQ is CLOSEd when the relay sends EOSE.
    private func sendProfileRequest(to url: URL, subId: String, pubkeys: [String]) {
        let filter: [String: Any] = [
            "kinds": [0, 10002, 10050, 10000, 10063],
            "authors": pubkeys
        ]
        guard let reqData = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: reqData, encoding: .utf8) else { return }

        let pool = Self.profileLookups
        let key = url.absoluteString
        if let until = pool.cooldownUntil[key], until > Date() {
            profileSubscriptionEnded(subId, answered: false)
            return
        }
        pool.cooldownUntil[key] = nil

        if let socket = pool.sockets[key] {
            switch socket.client.connectionState {
            case .connected:
                socket.client.send(text: req)
                scheduleProfileSocketIdleClose(key: key)
                return
            case .connecting, .disconnected:
                pool.sockets[key]?.pending.append(req)
                return
            case .error:
                closeProfileSocket(key: key)
            }
        }

        let client = WebSocketClient()
        client.isTemporary = true
        var socket = ProfileLookupPool.Socket(client: client, pending: [req])

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in self?.handleProfileLookupMessage(message, from: key, client: client) }
            .store(in: &socket.subscriptions)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, let client, pool.sockets[key]?.client === client else { return }
                switch state {
                case .connected:
                    pool.sockets[key]?.opened = true
                    let queued = pool.sockets[key]?.pending ?? []
                    pool.sockets[key]?.pending.removeAll()
                    queued.forEach { client.send(text: $0) }
                    self.scheduleProfileSocketIdleClose(key: key)
                case .error:
                    // Refused (429 and friends), timed out or dropped: leave
                    // that relay alone for a while instead of redialling it.
                    pool.cooldownUntil[key] = Date().addingTimeInterval(ProfileLookupPool.cooldownSeconds)
                    self.closeProfileSocket(key: key)
                case .disconnected:
                    // The relay hung up on an open socket: drop it, so the
                    // next lookup dials again instead of queueing forever.
                    if pool.sockets[key]?.opened == true { self.closeProfileSocket(key: key) }
                case .connecting:
                    break
                }
            }
            .store(in: &socket.subscriptions)

        pool.sockets[key] = socket
        client.connect(url: url)
    }

    /// Runs on processingQueue. EOSE and CLOSED end that REQ here and never
    /// reach `processMessage`, which would count them against the feed's own
    /// subscriptions. Events are passed on only once their signature checks.
    private func handleProfileLookupMessage(_ message: String, from relay: String, client: WebSocketClient) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2, let type = json[0] as? String else { return }
        switch type {
        case "EVENT":
            guard json.count >= 3, let ev = json[2] as? [String: Any],
                  let id = ev["id"] as? String,
                  !Self.profileLookups.alreadyVerified(id),
                  NostrEventVerifier.isValid(ev) else { return }
            // Marked only after it checks: a forged copy can reuse a real id.
            Self.profileLookups.markVerified(id)
            processMessage(message, from: relay)
        case "EOSE", "CLOSED":
            guard let subId = json[1] as? String, subId.hasPrefix("meta-") else { return }
            if type == "EOSE",
               let closeData = try? JSONSerialization.data(withJSONObject: ["CLOSE", subId] as [Any]),
               let close = String(data: closeData, encoding: .utf8) {
                client.send(text: close)
            }
            let answered = type == "EOSE"
            DispatchQueue.main.async { [weak self] in self?.profileSubscriptionEnded(subId, answered: answered) }
        default:
            break
        }
    }

    private func profileSubscriptionEnded(_ subId: String, answered: Bool) {
        if let batch = Self.profileLookups.subscriptionEnded(subId, answered: answered) {
            finishProfileBatch(batch)
        }
    }

    private func scheduleProfileSocketIdleClose(key: String) {
        let pool = Self.profileLookups
        pool.sockets[key]?.idleClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeProfileSocket(key: key) }
        pool.sockets[key]?.idleClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ProfileLookupPool.idleSeconds, execute: work)
    }

    private func closeProfileSocket(key: String) {
        guard let socket = Self.profileLookups.sockets.removeValue(forKey: key) else { return }
        socket.idleClose?.cancel()
        socket.client.disconnect()
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
        let pool = Self.profileLookups
        let missing = pubkeys.filter {
            (force || (profiles[$0] == nil && !pool.recentlyMissed($0))) && !profilesInFlight.contains($0)
        }
        guard !missing.isEmpty else { return }

        for pubkey in missing {
            profilesInFlight.insert(pubkey)
            profileFetchQueue.insert(pubkey)
        }

        if profileFlushCancellable == nil {
            setupMetadataFlusher()
        }
    }

    /// Profile lookups share one pool for the whole app.
    static let profileLookups = ProfileLookupPool()
}

/// Profile lookups the Nostr way: one long-lived socket per relay, a REQ per
/// batch that is CLOSEd on EOSE, and a back-off for keys no relay had.
/// It replaced a fresh socket per relay on every 0.5 s flush, each dropped
/// after 5 s: on 2026-10-12 opening the WoT tab made 26 of them in 40 s.
/// Everything but the verified-id set is used on the main thread only.
final class ProfileLookupPool {
    struct Socket {
        let client: WebSocketClient
        /// REQs waiting for the handshake to finish.
        var pending: [String] = []
        var subscriptions = Set<AnyCancellable>()
        var idleClose: DispatchWorkItem?
        /// Has reached .connected once; a new client starts out .disconnected.
        var opened = false
    }

    static let authorsPerReq = 250
    static let idleSeconds: TimeInterval = 30
    static let cooldownSeconds: TimeInterval = 120
    static let batchDeadline: TimeInterval = 10
    /// How long a key no relay had is left alone before it is asked again.
    static let missBackoff: TimeInterval = 10 * 60

    var sockets: [String: Socket] = [:]
    var cooldownUntil: [String: Date] = [:]
    var missedAt: [String: Date] = [:]

    private var nextBatch = 0
    private var batchPubkeys: [Int: [String]] = [:]
    private var batchOpenSubs: [Int: Int] = [:]
    private var batchAnswered: Set<Int> = []
    private var subBatch: [String: Int] = [:]
    private var subRelay: [String: String] = [:]

    private let seenLock = NSLock()
    private var seenIds = Set<String>()

    func recentlyMissed(_ pubkey: String) -> Bool {
        guard let at = missedAt[pubkey] else { return false }
        if Date().timeIntervalSince(at) < Self.missBackoff { return true }
        missedAt[pubkey] = nil
        return false
    }

    func startBatch(pubkeys: [String]) -> Int {
        nextBatch &+= 1
        batchPubkeys[nextBatch] = pubkeys
        batchOpenSubs[nextBatch] = 0
        return nextBatch
    }

    func track(subId: String, relay: String, batch: Int) {
        subBatch[subId] = batch
        subRelay[subId] = relay
        batchOpenSubs[batch, default: 0] += 1
    }

    /// The batch whose last open REQ this was, if any.
    func subscriptionEnded(_ subId: String, answered: Bool) -> Int? {
        subRelay[subId] = nil
        guard let batch = subBatch.removeValue(forKey: subId),
              let open = batchOpenSubs[batch] else { return nil }
        if answered { batchAnswered.insert(batch) }
        batchOpenSubs[batch] = open - 1
        return open - 1 <= 0 ? batch : nil
    }

    /// Ends a batch once: the pubkeys it asked for, the REQs (with their
    /// relay) still unanswered and whether any relay sent EOSE; nil if it
    /// already ended.
    func endBatch(_ batch: Int) -> (pubkeys: [String], unanswered: [(subId: String, relay: String)], anyAnswered: Bool)? {
        guard let pubkeys = batchPubkeys.removeValue(forKey: batch) else { return nil }
        let anyAnswered = batchAnswered.remove(batch) != nil
        batchOpenSubs[batch] = nil
        let open = subBatch.filter { $0.value == batch }.keys
        let unanswered = open.compactMap { id in subRelay[id].map { (subId: id, relay: $0) } }
        for id in open { subBatch[id] = nil; subRelay[id] = nil }
        return (pubkeys, unanswered, anyAnswered)
    }

    /// Every relay asked answers with the same kind 0, so once a copy has
    /// checked out the others are dropped unchecked. Processing queue.
    func alreadyVerified(_ id: String) -> Bool {
        seenLock.lock(); defer { seenLock.unlock() }
        return seenIds.contains(id)
    }

    func markVerified(_ id: String) {
        seenLock.lock(); defer { seenLock.unlock() }
        if seenIds.count > 20_000 { seenIds.removeAll() }
        seenIds.insert(id)
    }
}
