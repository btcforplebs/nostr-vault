import Foundation

/// The only places the owner's relay list (kind 10002) and DM inbox (kind
/// 10050) are published: Save in Settings > Relays, the Publish relay list
/// switch and dashboard button, a saved Mac relay address change, and a new
/// account's starter list. Launch and setup never publish them (Logen
/// 2026-10-31). Mirrors Android `NostrServiceListPublishing.kt`.
extension NostrService {

    /// The owner's published relay list and DM inbox, for Settings > Relays.
    /// A list counts as known when it was found, or both indexer relays
    /// answered without one (`RelayDraft.settled`); otherwise the cached copy
    /// is shown and Save won't publish over it.
    @MainActor
    func lookupOwnerRelayLists() async -> RelayDraft.Published {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString else { return RelayDraft.Published() }
        let ask = Array(config.readRelays.prefix(3)) + RelayDraft.indexers
        async let relayList = lookupNewestReplaceable(kind: 10002, for: owner, alsoAsk: ask)
        async let dmList = lookupNewestReplaceable(kind: 10050, for: owner, alsoAsk: ask + config.dmInboxRelays)
        let rl = await relayList
        let dl = await dmList
        let lists = rl.event.map { ProfileRepository.parseRelayListTags($0.tags) }
        let read = lists?.inbox ?? relayLists[owner] ?? []
        let write = lists?.write ?? outboxRelays[owner] ?? []
        let dms = dl.event.map { ProfileRepository.parseDMRelayListTags($0.tags) } ?? []
        #if DEBUG
        print("NostrService: relay lists looked up: 10002 \(rl.answered)/\(rl.asked) found=\(rl.event != nil), 10050 \(dl.answered)/\(dl.asked) found=\(dl.event != nil)")
        #endif
        return RelayDraft.Published(
            read: read.filter { !Self.isLoopbackRelay($0) },
            write: write.filter { !Self.isLoopbackRelay($0) },
            dms: dms.filter { !Self.isLoopbackRelay($0) },
            relayListKnown: RelayDraft.settled(found: rl.event != nil, answeredBy: rl.answeredBy),
            dmListKnown: RelayDraft.settled(found: dl.event != nil, answeredBy: dl.answeredBy))
    }

    /// Publishes `tags` as kind 10002 for `npub` (the owner by default).
    @MainActor
    func publishRelayListTags(_ tags: [[String]], signAsNpub npub: String? = nil) {
        let signer = npub ?? ConfigService.shared.config.ownerNpub
        guard let hex = Bech32.decode(signer)?.hexString else { return }
        Task {
            guard let event = await signEventAsync(kind: 10002, content: "", tags: tags, signAsNpub: signer),
                  event.pubkey.lowercased() == hex.lowercased() else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10002 relay list")
                #endif
                return
            }
            postEvent(event)
        }
    }

    /// Publishes exactly `relays` as the owner's kind 10050 and stamps it as
    /// the newest change. An emptied list goes out empty rather than as the
    /// app's defaults. Loopback entries never go out.
    @MainActor
    func publishOwnerDMRelays(_ relays: [String]) {
        let configService = ConfigService.shared
        let owner = configService.config.ownerNpub
        guard let hex = Bech32.decode(owner)?.hexString else { return }
        let tags = relays.filter { !Self.isLoopbackRelay($0) }.map { ["relay", $0] }
        configService.config.dmRelaysUpdatedAt = Int64(Date().timeIntervalSince1970)
        configService.save()
        Task {
            guard let event = await signEventAsync(kind: 10050, content: "", tags: tags, signAsNpub: owner),
                  event.pubkey.lowercased() == hex.lowercased() else { return }
            postEvent(event)
        }
    }

    /// The owner saved a new Mac relay address: on the published DM inbox
    /// list, `oldInbox` becomes `newInbox` and every other entry stays as
    /// published. Nothing goes out when no list was found, so the app's
    /// defaults never reach it.
    @MainActor
    func publishOwnerDMInboxMove(from oldInbox: String, to newInbox: String) {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString else { return }
        Task {
            let lookup = await lookupNewestReplaceable(kind: 10050, for: owner, alsoAsk: config.dmInboxRelays + RelayDraft.indexers)
            guard let event = lookup.event else {
                #if DEBUG
                print("NostrService: DM inbox move: no published list found; not published")
                #endif
                return
            }
            let published = ProfileRepository.parseDMRelayListTags(event.tags)
            let moved = Self.dmInboxMoved(published, from: oldInbox, to: newInbox)
            guard moved != published else { return }
            publishOwnerDMRelays(moved)
        }
    }

    /// `published` with `oldInbox` swapped for `newInbox` in its place (or
    /// `newInbox` first when the old one wasn't there). Blank addresses are skipped.
    static func dmInboxMoved(_ published: [String], from oldInbox: String, to newInbox: String) -> [String] {
        let old = RelayMatrix.key(oldInbox)
        let new = HavenConfig.normalizedRelayURL(newInbox)
        var result = published
        if let i = result.firstIndex(where: { !old.isEmpty && RelayMatrix.key($0) == old }) {
            if new.isEmpty { result.remove(at: i) } else { result[i] = new }
        } else if !new.isEmpty {
            result.insert(new, at: 0)
        }
        var seen = Set<String>()
        return result.filter { seen.insert(RelayMatrix.key($0)).inserted }
    }

    /// The Publish relay list switch and the dashboard Publish button (Logen
    /// 1A): the account's own published relay list plus, for the owner, the
    /// vault's own relays; never this device's defaults. Nothing goes out
    /// when the relays didn't settle whether a list exists, or when there is
    /// nothing to add. Same rule as Android `publishRelayListImpl`.
    @MainActor
    func publishOwnRelaysInRelayList(forNpub npub: String) {
        guard let hex = Bech32.decode(npub)?.hexString else { return }
        let config = ConfigService.shared.config
        Task {
            let lookup = await lookupNewestReplaceable(kind: 10002, for: hex,
                                                       alsoAsk: Array(config.readRelays.prefix(3)) + RelayDraft.indexers)
            guard RelayDraft.settled(found: lookup.event != nil, answeredBy: lookup.answeredBy) else {
                #if DEBUG
                print("NostrService: relay list for \(npub.prefix(12)) not settled; not published")
                #endif
                return
            }
            // Their list as published, tags and all, with the vault's own
            // relays put first when missing.
            let existing = lookup.event?.tags.filter { $0.count >= 2 && $0[0] == "r" } ?? []
            let listed = Set(existing.map { RelayMatrix.key($0[1]) })
            let ownRelays = npub == config.ownerNpub ? config.ownPublicRelays : []
            let missing = HavenConfig.publicRelayListTags(ownRelays: ownRelays, read: [], write: [])
                .filter { !listed.contains(RelayMatrix.key($0[1])) }
            guard !missing.isEmpty else { return }
            let tags = missing + existing
            publishRelayListTags(tags, signAsNpub: npub)
        }
    }
}
