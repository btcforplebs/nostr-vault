import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Blocks (`add`) or unblocks (`remove`) people, by npub, on
    /// `accountNpub`'s kind 10000, a list other clients edit too. Only those
    /// entries change on the newest list: everyone else on it, the muted
    /// words, hashtags and threads, and the rest of the encrypted private
    /// part are kept. An unblock also takes the person out of the private part.
    /// `localBlocks`, this device's blocks after the change, is published
    /// only when the account has no list anywhere. When the list can't be
    /// fetched nothing is published and the person is told why.
    @MainActor
    func publishMuteListChange(for accountNpub: String, add: [String] = [], remove: [String] = [], localBlocks: [String]) {
        let hexKeys: ([String]) -> [String] = { npubs in
            npubs.compactMap { Bech32.decode($0.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString }
        }
        guard let author = Bech32.decode(accountNpub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString else { return }
        let action = add.isEmpty ? "Unblock" : "Block"

        Task {
            // The relays the mute list is read from at launch, so a block
            // builds on the list another app last wrote, not an older copy.
            let alsoAsk = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
            let lookup = await lookupNewestReplaceable(kind: 10000, for: author, alsoAsk: alsoAsk)
            let base: (tags: [[String]], content: String)
            switch ListMerge.editBase(lookup, held: MuteListStore.shared.storedEvent(forHex: author),
                                            own: ConfigService.shared.config.writeRelays.filter { !Self.isLoopbackRelay($0) }, createdAt: { $0.created_at }) {
            case .list(let event):
                base = (event.tags, event.content)
            case .none:
                base = (hexKeys(localBlocks).map { ["p", $0] }, "")
            case .unknown:
                #if DEBUG
                print("NostrService: Kind 10000: list not fetched (\(lookup.answered)/\(lookup.asked) relays answered); not published")
                #endif
                ActionToastManager.shared.show(
                    icon: "exclamationmark.triangle.fill",
                    message: "\(action) saved on this device only: your relays didn't send your mute list, and publishing without it would erase blocks set in other apps. Try again later.",
                    tone: .error)
                return
            }
            // An unblock takes the person out of the encrypted part too, or
            // reading the published list back blocks them again.
            let content: String
            let privateHex = MuteListStore.shared.privatePubkeys(forAccount: accountNpub)
            switch await ListMerge.removingPrivate(
                content: base.content, remove: hexKeys(remove),
                knownPrivate: hexKeys(remove).contains { privateHex.contains($0.lowercased()) },
                decrypt: { try await MuteListStore.decryptToSelf($0, me: author, nip04: $1) },
                encrypt: { try await MuteListStore.encryptToSelf($0, me: author, nip04: $1) }) {
            case .content(let edited):
                content = edited
            case .failed:
                ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                               message: "\(action) saved on this device only: your private blocks couldn't be updated",
                                               tone: .error)
                return
            }
            let tags = ListMerge.edit(name: "p", base: base.tags, add: hexKeys(add), remove: hexKeys(remove))
            guard let event = await signEventAsync(kind: 10000, content: content, tags: tags, signAsNpub: accountNpub) else {
                ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                               message: "\(action) saved on this device only: your signer didn't answer",
                                               tone: .error)
                return
            }
            postEvent(event)
            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
            ConfigService.shared.save()
            // This device's blocks become the published list, so people
            // another app blocked show as blocked here too.
            applyOwnMuteList(event)
            #if DEBUG
            print("NostrService: Published Kind 10000 with \(tags.count) tags for \(author.prefix(8))")
            #endif
        }
    }

    /// Signs and posts `kind` for `author`, built by `build` from the newest
    /// published one (nil when there is none). Skips when no relay answered,
    /// since publishing then would overwrite a list this device never saw.
    @MainActor
    private func publishMergedList(kind: Int, author: String, signAsNpub: String?,
                                   build: (NostrEvent?) -> (tags: [[String]], content: String)) async -> NostrEvent? {
        guard !author.isEmpty else { return nil }
        let alsoAsk = Array(ConfigService.shared.config.readRelays.prefix(3))
        let lookup = await lookupNewestReplaceable(kind: kind, for: author, alsoAsk: alsoAsk)
        if lookup.event == nil && lookup.answered == 0 {
            #if DEBUG
            print("NostrService: Kind \(kind): no relay answered; not published")
            #endif
            return nil
        }
        let (tags, content) = build(lookup.event)
        guard let event = await signEventAsync(kind: kind, content: content, tags: tags, signAsNpub: signAsNpub) else {
            #if DEBUG
            print("NostrService: Failed to sign Kind \(kind) list")
            #endif
            return nil
        }
        postEvent(event)
        #if DEBUG
        print("NostrService: Published Kind \(kind) list with \(tags.count) tags for \(author.prefix(8))")
        #endif
        return event
    }

    /// Publishes `kind` for `author`: `local` as `name` tags, plus the entries
    /// other clients added. An entry counts as added elsewhere when it is
    /// published but was not in what this device last published (the base in
    /// `ListMerge.Bases`), so a local removal still removes it.
    @MainActor
    private func publishEntryList(kind: Int, name: String, local: [String], author: String, signAsNpub: String?) async {
        let bases = ListMerge.Bases.shared
        let baseKey = "\(kind):\(author)"
        _ = await publishMergedList(kind: kind, author: author, signAsNpub: signAsNpub) { published in
            let base = bases.get(baseKey).map { Set($0.map(ListMerge.key)) }
            let tags = ListMerge.tags(name: name, local: local, published: published?.tags ?? []) { entry in
                base.map { !$0.contains(ListMerge.key(entry)) } ?? true
            }
            bases.put(baseKey, local)
            return (tags, published?.content ?? "")
        }
    }

    /// BUD-03: Publishes a Kind 10063 (User Server List) event advertising Blossom mirrors.
    /// Call whenever blossomMirrors changes (settings, setup wizard).
    /// Pass fipsDetectedNpub when available to include the detected .fips address.
    @MainActor
    /// Keeps the newest 10063 per author (persisted), so a replay is ignored.
    /// `signedByAuthor`: the event's signature was checked and is the pubkey's;
    /// an event that wasn't is refused and never moves the stamp.
    @discardableResult
    func acceptServerListStamp(pubkey: String, createdAt: Int64, id: String, signedByAuthor: Bool) -> Bool {
        var stamps = UserDefaults.standard.dictionary(forKey: Self.serverListStampsKey) as? [String: String] ?? [:]
        let seen = stamps[pubkey].flatMap { s -> (createdAt: Int64, id: String)? in
            let parts = s.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let t = Int64(parts[0]) else { return nil }
            return (t, String(parts[1]))
        }
        guard HomeVaultLogic.keepsServerList(signedByAuthor: signedByAuthor, createdAt: createdAt, id: id, than: seen) else { return false }
        stamps[pubkey] = "\(createdAt):\(id)"
        UserDefaults.standard.set(stamps, forKey: Self.serverListStampsKey)
        return true
    }

    // v2: builds before PR 999 stamped any 10063 a relay sent, signed or not, and
    // a forged far-future created_at would outrank every real list forever. The
    // v1 stamps (and the lists cached with them) are dropped once, in
    // ProfileRepository.loadServerLists, so the next signed list wins again.
    static let serverListStampsKey = "serverListStamps.v2"

    /// What this device put in the owner's 10063 last time (its own servers
    /// and mesh entries), so a removal here removes only those.
    static func serverListManaged(owner: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "serverListManaged.\(owner)") ?? []
    }

    func publishServerList(fipsDetectedNpub: String? = nil) {
        var servers = ConfigService.shared.config.activeBlossomMirrors(detectedNpub: fipsDetectedNpub)
        let owner = activeHexPubkey
        // Merge into the newest list, never replace it (one rule for every
        // phone): another phone's servers and mesh entries stay; only the
        // servers this phone manages change. Public servers first (NIP-F1).
        var ownMesh: String?
        var photoNpub: String?
        #if os(iOS)
        // This phone's own mesh npub is never listed (and is dropped from an
        // older list that had it): the main node is for the owner's devices.
        ownMesh = FipsMeshService.shared.ownMeshNpub
        // The home vault this phone sends to, and the Mac it is linked to:
        // listed by the phone, so neither needs the owner's key.
        servers += HomeVaultLogic.phoneMeshEntries(homeVault: HomeVaultSender.shared.homeVault,
                                                   macMeshNpub: ConfigService.shared.config.macRelayMeshNpub,
                                                   ownerHex: owner)
        // A vault this phone listed before stays listed while it is still in My Devices.
        for entry in HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: Self.serverListManaged(owner: owner),
                                                          myDevices: FipsMeshDevices.current(ConfigService.shared.config).map(\.npub))
            where !servers.contains(entry) {
            servers.append(entry)
        }
        #else
        // The Mac lists its photo node, so a photo post points viewers to the
        // Mac with no setup; phones keep the entry through this same merge.
        photoNpub = PhotoNode.npub()
        #endif
        let managedKey = "serverListManaged.\(owner)"
        let previouslyManaged = Set(Self.serverListManaged(owner: owner))
        let ownMeshNpub = ownMesh, photo = photoNpub, current = servers

        Task {
            // Start from the newest list on the relays, not this phone's cache
            // (same rule as Android): the cache only when the relays could not
            // say, and nothing when they all confirmed there is none.
            let lookup = await lookupNewestReplaceable(kind: 10063, for: owner, alsoAsk: [RelayConfiguration.serverListIndexerRelay])
            let existing: [String]
            if let newest = lookup.event {
                // lookupNewestReplaceable keeps only events whose author and signature it checked.
                if acceptServerListStamp(pubkey: owner, createdAt: newest.created_at, id: newest.id, signedByAuthor: true) {
                    serverLists[owner] = ProfileRepository.parseServerListTags(newest.tags)
                }
                existing = serverLists[owner] ?? []
            } else if lookup.confirmedNone {
                existing = []
            } else {
                existing = serverLists[owner] ?? []
            }
            guard let merged = HomeVaultLogic.mergeServerList(
                existing: existing,
                current: current,
                previouslyManaged: previouslyManaged,
                ownMeshNpub: ownMeshNpub,
                photoNpub: photo
            ) else {
                #if DEBUG
                print("NostrService: No usable Blossom server, skipping Kind 10063 publish")
                #endif
                return
            }
            // Nothing changed: no new signed event on the public relays (kiosk
            // mode republishes on every app switch; readers already hold this).
            if merged == existing {
                UserDefaults.standard.set(current, forKey: managedKey)
                return
            }
            let tags = merged.map { ["server", $0] }
            if let event = await signEventAsync(kind: 10063, content: "", tags: tags) {
                // Ours is now the newest: merge from it next time, even before it echoes back.
                // Signed here, by this account.
                if acceptServerListStamp(pubkey: event.pubkey, createdAt: event.created_at, id: event.id, signedByAuthor: true) {
                    serverLists[event.pubkey] = merged
                }
                UserDefaults.standard.set(current, forKey: managedKey)
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10063 server list with \(tags.count) servers")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10063 server list")
                #endif
            }
        }
    }

    /// A loopback address means "this machine". Advertising one to the network,
    /// or publishing someone else's DM to one, sends the event to the *sender's*
    /// own relay — the write succeeds, nothing errors, and the recipient never
    /// sees it. Never let one reach a relay list or a publish target.
    static func isLoopbackRelay(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            let lowered = urlString.lowercased()
            return lowered.contains("127.0.0.1") || lowered.contains("localhost") || lowered.contains("[::1]")
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0"
    }

    /// NIP-51: publishes the owner's blocked relay list (kind 10006), the
    /// relays set to Never connect. Public `relay` tags merged with the ones
    /// other clients added. An empty local list is published too, so
    /// unblocking the last relay clears it.
    func publishBlockedRelayList() {
        let config = ConfigService.shared.config
        let relays = config.blockedRelays.map(HavenConfig.normalizedRelayURL)
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString else { return }
        Task { @MainActor in
            await publishEntryList(kind: 10006, name: "relay", local: relays, author: owner, signAsNpub: config.ownerNpub)
        }
    }

    /// Takes the owner's newest published DM inbox list (kind 10050) when it
    /// is newer than this device's. Never publishes: launch and setup used to
    /// publish this device's list, or the app's defaults when the account had
    /// none, and signed one for every other account too, without anyone
    /// saving anything (Logen 2026-10-31). Only Save in Settings > Relays
    /// publishes it; see `NostrService+RelayListSave`.
    @MainActor
    func adoptPublishedDMRelayList() async {
        let configService = ConfigService.shared
        let config = configService.config
        guard let ownerHex = Bech32.decode(config.ownerNpub)?.hexString else { return }
        let lookup = await lookupNewestReplaceable(kind: 10050, for: ownerHex, alsoAsk: config.dmInboxRelays)
        guard let event = lookup.event else { return }
        // A published list can still carry relays that are gone; adopting it
        // would undo the one-time drop of them from the saved config.
        let published = ProfileRepository.parseDMRelayListTags(event.tags)
            .filter { !Self.isLoopbackRelay($0) && !HavenConfig.isDeadRelay($0) }
        let action = HavenConfig.dmInboxSyncAction(
            local: configService.config.dmInboxRelays,
            localUpdatedAt: configService.config.dmRelaysUpdatedAt,
            published: published, publishedAt: event.created_at)
        guard action == .adopt else { return }
        if !published.isEmpty {
            configService.config.dmRelays = published
        }
        configService.config.dmRelaysUpdatedAt = event.created_at
        configService.save()
        #if DEBUG
        print("NostrService: Adopted published DM inbox list (\(published.count) relays)")
        #endif
    }
}

#if os(iOS)
/// The Mac this phone is linked to by mesh npub. A Mac without the owner's
/// key can't sign the 10063, so the phone lists it (Logen, 2026-10-21).
enum LinkedMacEntry {
    /// Republishes when the owner's kept 10063 lacks the linked Mac. Checked
    /// when a signed 10063 arrives (the newest replays at every launch) and
    /// when the Mac is linked. At most once per npub every 5 minutes.
    @MainActor static func ensureListed(owner: String, nostr: NostrService) {
        guard owner == nostr.activeHexPubkey,
              let mac = ConfigService.shared.config.macRelayMeshNpub,
              HomeVaultLogic.photoNodeMissing(from: nostr.serverLists[owner], photoNpub: mac) else { return }
        let key = "\(owner):\(mac)"
        if let last = lastTry[key], Date().timeIntervalSince(last) < 300 { return }
        lastTry[key] = Date()
        nostr.publishServerList()
    }
    @MainActor private static var lastTry: [String: Date] = [:]
}
#endif

#if os(macOS)
/// The Mac's photo node: its own mesh node (MacFipsMeshService), which also
/// lets strangers read photos by hash through the public seeds, capped. Its
/// npub goes in the owner's 10063.
enum PhotoNode {
    /// This Mac's mesh npub while its Mesh switch is on and the engine runs
    /// (it starts only with a device added), else nil.
    @MainActor static func npub() -> String? {
        HomeVaultLogic.macPhotoNpub(MacFipsMeshService.photoNpub(), engineRunning: MacFipsMeshService.shared.running)
            .flatMap { HomeVaultLogic.meshNpub(fromInput: $0) }
    }

    /// Republishes when the owner's kept 10063 lacks the photo node, so the
    /// entry appears with no setup and comes back if a stale list (another
    /// device's) dropped it. Checked when a 10063 arrives (even one already
    /// seen: the newest list replays on every launch and is not "newer") and
    /// when the Mac's mesh npub becomes known. At most once per npub every
    /// 5 minutes, so a publish that never lands is retried, not looped.
    @MainActor static func ensureListed(owner: String, nostr: NostrService) {
        guard owner == nostr.activeHexPubkey, let npub = npub(),
              HomeVaultLogic.photoNodeMissing(from: nostr.serverLists[owner], photoNpub: npub) else { return }
        let key = "\(owner):\(npub)"
        if let last = lastTry[key], Date().timeIntervalSince(last) < 300 { return }
        lastTry[key] = Date()
        nostr.publishServerList()
    }
    @MainActor private static var lastTry: [String: Date] = [:]
}
#endif
