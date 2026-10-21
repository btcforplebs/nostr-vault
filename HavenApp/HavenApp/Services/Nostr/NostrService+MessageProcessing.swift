import Foundation
import Combine
import SwiftUI

extension NostrService {
    func processMessage(_ message: String, from urlString: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else {
            return
        }

        if type == "EOSE", let subId = json[1] as? String {
            // Close historical subscriptions immediately after EOSE
            if subId.contains("-hist-") {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8),
                   let client = clients[urlString] {
                    client.send(text: closeStr)
                    #if DEBUG
                    print("NostrService: Closed historical subscription \(subId)")
                    #endif
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Flush any buffered events before marking EOSE complete
                self.flushEventBuffer()
                self.activeSubscriptionCount -= 1
                if self.activeSubscriptionCount <= 0 {
                    self.isFetching = false
                    self.activeSubscriptionCount = 0
                    self.cancelFetchWatchdog()
                }
                self.events.sort(by: { $0.created_at > $1.created_at })
                self.eventUpdateSubject.send()
            }
        }

        if type != "EVENT" { return }

        guard json.count >= 3 else { return }

        if let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Inject feed-relevant events from external relays into the local relay
            // so they persist beyond the current session (e.g. mac relay events).
            if let sourceURL = URL(string: urlString), !isLocalRelay(sourceURL) {
                FeedService.shared.injectExternalEvent(eventDict, eventId: event.id)
            }

            // Early dedup for replaceable events (kind 3 contact lists, etc.)
            // that flood on every re-subscription. Skip before any expensive processing.
            let replaceableKinds: Set<Int> = [3]
            if replaceableKinds.contains(event.kind) && hasSeen(event.id) {
                return
            }

            if event.kind == 0 {
                let content = event.content
                let pubkey = event.pubkey
                let createdAt = event.created_at
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let existing = self.profileWrites.current(pubkey, stored: self.profiles)
                    if let result = ProfileRepository.parseMetadataContent(content, pubkey: pubkey, existingProfile: existing, createdAt: createdAt),
                       result.changed {
                        self.queueProfileWrite(result.profile)
                    }
                }
                return
            }

            if event.kind == 10002 {
                let parsed = ProfileRepository.parseRelayListTags(event.tags)
                let pubkey = event.pubkey
                let createdAt = event.created_at
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.relaysInFlight.remove(pubkey)
                    if let known = self.relayListCreatedAt[pubkey], createdAt < known { return }
                    self.relayListCreatedAt[pubkey] = createdAt
                    if !parsed.inbox.isEmpty { self.relayLists[pubkey] = parsed.inbox }
                    if !parsed.write.isEmpty { self.outboxRelays[pubkey] = parsed.write }
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10050 {
                let dmRelays = ProfileRepository.parseDMRelayListTags(event.tags)
                let pubkey = event.pubkey
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !dmRelays.isEmpty { self.dmRelayLists[pubkey] = dmRelays }
                    self.dmRelaysInFlight.remove(pubkey)
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10063 {
                let servers = ProfileRepository.parseServerListTags(event.tags)
                let pubkey = event.pubkey
                let createdAt = event.created_at, eventId = event.id
                // This list picks the mesh node a photo is read from: a relay can
                // serve any event under any author, so only a signature makes it the
                // author's (Tara's NIP-F1 check). Checked here, off the main thread.
                let signed = NostrEventVerifier.isValid(eventDict)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // A relay replaying an older list must not undo a newer one:
                    // every phone merges into the list it keeps here.
                    let accepted = self.acceptServerListStamp(pubkey: pubkey, createdAt: createdAt, id: eventId, signedByAuthor: signed)
                    if accepted {
                        if !servers.isEmpty { self.serverLists[pubkey] = servers }
                        self.saveProfilesThrottled()
                    }
                    #if os(macOS)
                    // Also for a list already seen: the newest one replays at
                    // every launch and is never "newer" than itself.
                    if signed { PhotoNode.ensureListed(owner: pubkey, nostr: self) }
                    #elseif os(iOS)
                    if signed { LinkedMacEntry.ensureListed(owner: pubkey, nostr: self) }
                    #endif
                }
                return
            }

            if event.kind == 10000 {
                let blockedHexKeys = ProfileRepository.parseMuteListPTags(event.tags)
                let allNpubs = ConfigService.shared.allAccountNpubs
                if let matchingNpub = allNpubs.first(where: { npub in
                    Bech32.decode(npub)?.hexString == event.pubkey
                }) {
                    let blockedNpubs = ProfileRepository.hexKeysToNpubs(blockedHexKeys)
                    let eventTimestamp = event.created_at
                    DispatchQueue.main.async {
                        let currentBlocks = ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] ?? []
                        let lastSync = ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] ?? 0

                        if eventTimestamp >= lastSync && Set(currentBlocks) != Set(blockedNpubs) {
                            ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] = blockedNpubs
                            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] = eventTimestamp
                            if matchingNpub == ConfigService.shared.config.ownerNpub {
                                ConfigService.shared.config.blacklistedNpubs = blockedNpubs
                            }
                            ConfigService.shared.save()
                            #if DEBUG
                            print("NostrService: Synced \(blockedNpubs.count) blocks from Kind 10000 for \(matchingNpub.prefix(8))")
                            #endif
                            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
                        }
                    }
                }
                return
            }

            if !markSeen(event.id) { return }

            var items: [MediaItem] = []

            if event.kind == 1063 {
                // Parse KIND 1063 — NIP-94 file metadata with "url" and "m" (mime) tags
                if let urlTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "url" }),
                   let url = URL(string: urlTag[1]) {
                    let mimeTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })?[1]
                    let mime = mimeTag ?? Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    items.append(MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime))
                }
            } else if NoteTagging.contentMediaIsAuthors(kind: event.kind) {
                let urls = extractMediaURLs(from: event.content)
                items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
            }

            // Buffer event instead of dispatching to main thread per-event
            bufferLock.lock()
            eventBuffer.append((event, items))
            bufferLock.unlock()
            scheduleBufferFlush()
        }
    }


    // MARK: - Seen-event dedup (thread-safe)

    /// Atomically records `id`: returns true if it was NOT seen before (and
    /// inserts it), false if already seen. Also trims the set when it grows
    /// large. Replaces the racy contains()/insert() pairs that previously ran on
    /// both the background processing queue and the main thread.
    func markSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        if seenEventIds.contains(id) { return false }
        seenEventIds.insert(id)
        // Prevent unbounded memory growth — trim oldest entries when large.
        if seenEventIds.count > 50_000 {
            let excess = seenEventIds.count - 40_000
            seenEventIds = Set(seenEventIds.dropFirst(excess))
        }
        return true
    }

    /// Thread-safe membership check.
    private func hasSeen(_ id: String) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        return seenEventIds.contains(id)
    }

    /// Thread-safe clear (used on account switch).
    func clearSeen() {
        seenLock.lock()
        defer { seenLock.unlock() }
        seenEventIds.removeAll()
    }

    // MARK: - Batched Event Flushing

    private func scheduleBufferFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bufferFlushTimer == nil else { return }
            self.bufferFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushEventBuffer()
                }
            }
        }
    }

    func flushEventBuffer() {
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil

        bufferLock.lock()
        let batch = eventBuffer
        eventBuffer.removeAll()
        bufferLock.unlock()

        guard !batch.isEmpty else { return }

        var newEvents: [NostrEvent] = []
        for (event, items) in batch {
            newEvents.append(event)
            if !items.isEmpty {
                noteMedia.append(contentsOf: items)
            }
        }

        // Efficiently merge and sort
        events.append(contentsOf: newEvents)

        // Only sort if we have a significant number of new events or the list is out of order
        // This is a trade-off: keep it snappy vs perfectly sorted at all times.
        if events.count > 1 {
            events.sort(by: { $0.created_at > $1.created_at })
        }

        if events.count > Self.maxEvents {
            events = Array(events.prefix(Self.maxEvents))
        }
        // Bound the heavy long-form bodies independently of the overall ceiling. `events`
        // is sorted newest→oldest, so this keeps the newest `maxLongFormEvents` articles
        // in full and drops older ones, without touching the lightweight bulk.
        let longFormCount = events.reduce(0) { $0 + ($1.kind == 30023 ? 1 : 0) }
        if longFormCount > Self.maxLongFormEvents {
            var kept = 0
            events = events.filter { event in
                guard event.kind == 30023 else { return true }
                kept += 1
                return kept <= Self.maxLongFormEvents
            }
        }
        if noteMedia.count > Self.maxNoteMedia {
            noteMedia.sort(by: { $0.dateAdded > $1.dateAdded })
            noteMedia = Array(noteMedia.prefix(Self.maxNoteMedia))
        }
        eventUpdateSubject.send()
    }

    /// Inject an externally-received event into the shared events array.
    /// Used by FeedService to forward zap receipts (Kind 9735) so the Viewer can display them.
    func injectEvent(_ event: NostrEvent) {
        guard markSeen(event.id) else { return }
        bufferLock.lock()
        eventBuffer.append((event, []))
        bufferLock.unlock()
        scheduleBufferFlush()
    }

    static func mimeFromExtension(_ url: URL) -> String? {
        EventPublisher.mimeFromExtension(url)
    }

    nonisolated static func mediaTypeFromMime(_ mime: String?, url: URL) -> MediaItem.MediaType {
        EventPublisher.mediaTypeFromMime(mime, url: url)
    }

    func extractMediaURLs(from content: String) -> [URL] {
        guard let regex = SupportedMediaFormats.mediaURLRegex else { return [] }
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))

        var urls: [URL] = []
        for result in results {
            let urlString = nsString.substring(with: result.range)
            if let url = URL(string: urlString), SupportedMediaFormats.isMediaURL(url) {
                urls.append(url)
            }
        }

        return urls.map { url in
            var finalURL = url

            // Normalize potential local/development URLs to use HTTP instead of HTTPS
            // We check for localhost, 127.0.0.1, and any URL that matches the current relayURL if it's local
            let isKnownLocal = finalURL.host == "localhost" ||
                               finalURL.host == "127.0.0.1" ||
                               ConfigService.shared.config.isLocal

            if finalURL.scheme == "https" && isKnownLocal {
                var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
                components?.scheme = "http"
                if let normalizedURL = components?.url {
                    finalURL = normalizedURL
                }
            }
            return finalURL
        }
    }
}
