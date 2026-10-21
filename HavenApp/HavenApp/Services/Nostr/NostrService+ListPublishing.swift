import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Publishes a signed Kind 10000 (Mute List) event to configured relays for the active account
    @MainActor
    func publishMuteList(for accountNpub: String, blockedNpubs: [String]) {
        // Convert npubs to hex pubkeys
        let hexKeys = blockedNpubs.compactMap { npub -> String? in
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(clean)?.hexString
        }

        guard let author = Bech32.decode(accountNpub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString else { return }

        Task {
            // The "p" tags are this device's blocks. The rest of the published
            // list (word, hashtag and thread mutes, and the encrypted private
            // mutes in content) was set in other clients and is kept.
            let event = await publishMergedList(kind: 10000, author: author, signAsNpub: accountNpub) { published in
                (ListMerge.tags(name: "p", local: hexKeys, published: published?.tags ?? []) { _ in false },
                 published?.content ?? "")
            }
            if let event {
                ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
                ConfigService.shared.save()
            }
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

    private static let serverListStampsKey = "serverListStamps.v1"

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
        // The home vault this phone sends to: listed by the sender, so the
        // kiosk itself never needs the owner's key.
        if let vault = HomeVaultSender.shared.homeVault, vault.ownerHex == owner {
            servers.append("fipsmesh://\(vault.meshNpub)/")
        }
        #else
        // The Mac lists its photo node, so a photo post points viewers to the
        // Mac with no setup; phones keep the entry through this same merge.
        photoNpub = PhotoNode.npub()
        #endif
        let managedKey = "serverListManaged.\(owner)"
        let previouslyManaged = Set(UserDefaults.standard.stringArray(forKey: managedKey) ?? [])
        let ownMeshNpub = ownMesh, photo = photoNpub, current = servers

        Task {
            // Start from the newest list on the relays, not this phone's cache
            // (same rule as Android): the cache only when the relays could not
            // say, and nothing when they all confirmed there is none.
            let lookup = await lookupNewestReplaceable(kind: 10063, for: owner, alsoAsk: [])
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

    /// NIP-17: Publishes a Kind 10050 (DM Relay List) event advertising which relays to send DMs to.
    /// Call whenever relay preferences change or during initial setup.
    ///
    /// Loopback entries are stripped: this list tells *other people* where to
    /// deliver, and our own 127.0.0.1 is meaningless to them. We previously
    /// inserted it at position 0, so every sender delivered our DMs into their
    /// own local relay and we received nothing.
    @MainActor
    func publishDMRelayList(dmRelays: [String], signAsNpub: String? = nil) {
        let reachable = dmRelays.filter { !Self.isLoopbackRelay($0) }
        guard !reachable.isEmpty else {
            #if DEBUG
            print("NostrService: No externally reachable DM relays, skipping Kind 10050 publish")
            #endif
            return
        }

        // NIP-17 tags are ["relay", url]. Builds before this wrote ["r", url],
        // which no other client reads — they saw an empty list and had nowhere
        // to deliver our DMs.
        let tags = reachable.map { ["relay", $0] }

        Task {
            if let event = await signEventAsync(kind: 10050, content: "", tags: tags, signAsNpub: signAsNpub) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10050 DM relay list with \(tags.count) relays")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10050 DM relay list")
                #endif
            }
        }
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

    /// Brings the owner's DM inbox list (kind 10050) into step across devices,
    /// and republishes kind 10050 for every other account that can sign.
    ///
    /// The owner's list is one list for all devices: the newest published
    /// 10050 is adopted unless this device changed its list more recently, in
    /// which case this device's list is published. Before, every device
    /// republished its own settings at launch, so whichever device opened last
    /// silently replaced the list the others had set.
    ///
    /// Publishing also heals lists from older builds (`wss://127.0.0.1:<port>`
    /// entries, which made senders write the gift wrap to their own machine).
    /// That's why this isn't gated behind the publish-relay-list toggle the
    /// way kind 10002 is: a broken 10050 silently breaks DMs.
    @MainActor
    func republishDMRelayListsForSignableAccounts() {
        let config = ConfigService.shared.config

        var accounts: [String] = config.whitelistedNpubs
        if !config.ownerNpub.isEmpty && !accounts.contains(config.ownerNpub) {
            accounts.insert(config.ownerNpub, at: 0)
        }

        Task {
            await syncOwnerDMInboxList()

            // Not gated on `config.isLocal`: the dmRelays list is remote either
            // way, and new-user setup always lands on a local relay URL.
            // Other accounts keep the plain list: the owner's Haven inbox
            // only takes DMs for the owner.
            let reachable = ConfigService.shared.config.dmRelays.filter { !Self.isLoopbackRelay($0) }
            guard !reachable.isEmpty else { return }
            for npub in accounts where npub != config.ownerNpub {
                let canSign = ConfigService.shared.hasCredential(forNpub: npub) || ConfigService.shared.hasBunkerConfig(forNpub: npub)
                guard canSign else { continue }

                // Only when it would change something. This ran on every
                // launch and signed the same list again every time; with a
                // remote signer that is a request to the person's signer app
                // for nothing, queued in front of whatever they do first. A
                // published list we cannot read (nobody answered, or it holds
                // loopback entries from an older build) still gets republished
                // — healing those is why this is not behind a toggle.
                if let hex = Bech32.decode(npub)?.hexString,
                   let newest = await fetchNewestDMRelayList(for: hex, alsoAsk: reachable),
                   Set(newest.relays) == Set(reachable) {
                    #if DEBUG
                    print("NostrService: DM relay list for \(npub.prefix(12))… already published and unchanged — not re-signing")
                    #endif
                    continue
                }

                publishDMRelayList(dmRelays: reachable, signAsNpub: npub)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Adopts or publishes the owner's DM inbox list — see
    /// `republishDMRelayListsForSignableAccounts`.
    @MainActor
    func syncOwnerDMInboxList() async {
        let configService = ConfigService.shared
        let config = configService.config
        guard !config.ownerNpub.isEmpty,
              let ownerHex = Bech32.decode(config.ownerNpub)?.hexString else { return }
        let canSign = !config.ownerNcryptsec.isEmpty || config.ownerHexKey != nil
            || configService.hasBunkerConfig(forNpub: config.ownerNpub)

        let lookup = await lookupNewestReplaceable(kind: 10050, for: ownerHex, alsoAsk: config.dmInboxRelays)
        // No relay answered: "none found" is unknown, not empty. A new install
        // of an existing account would otherwise publish the defaults over
        // the real list.
        if lookup.event == nil && lookup.answered == 0 {
            #if DEBUG
            print("NostrService: DM inbox sync: no relay answered; not published")
            #endif
            return
        }
        let newest = lookup.event.map { (relays: ProfileRepository.parseDMRelayListTags($0.tags), createdAt: $0.created_at) }
        // A published list can still carry relays that are gone; adopting it
        // would undo the one-time drop of them from the saved config.
        let published = newest?.relays.filter { !Self.isLoopbackRelay($0) && !HavenConfig.isDeadRelay($0) }

        var action = HavenConfig.dmInboxSyncAction(
            local: configService.config.dmInboxRelays,
            localUpdatedAt: configService.config.dmRelaysUpdatedAt,
            published: published, publishedAt: newest?.createdAt)

        if action == .adopt, let published, let newest {
            if !published.isEmpty {
                configService.config.dmRelays = published
            }
            configService.config.dmRelaysUpdatedAt = newest.createdAt
            configService.save()
            #if DEBUG
            print("NostrService: Adopted published DM inbox list (\(published.count) relays)")
            #endif
            // Adopting can still leave this device holding more than was
            // published (its own Haven inbox, or loopback entries dropped).
            action = HavenConfig.dmInboxSyncAction(
                local: configService.config.dmInboxRelays,
                localUpdatedAt: newest.createdAt,
                published: newest.relays, publishedAt: newest.createdAt)
        }

        guard action == .publish, canSign else { return }
        publishOwnerDMInboxList()
    }

    /// Publishes this device's DM inbox list for the owner and stamps it as the
    /// newest change. Call after the user edits the list or the Haven inbox
    /// address changes.
    @MainActor
    func publishOwnerDMInboxList() {
        let configService = ConfigService.shared
        let reachable = configService.config.dmInboxRelays.filter { !Self.isLoopbackRelay($0) }
        guard !reachable.isEmpty else { return }
        configService.config.dmRelaysUpdatedAt = Int64(Date().timeIntervalSince1970)
        configService.save()
        publishDMRelayList(dmRelays: reachable, signAsNpub: configService.config.ownerNpub)
    }

    /// NIP-65: Publishes a Kind 10002 (Relay List Metadata) event: the owner's
    /// own relays plus the Read and Write relays (`HavenConfig.publicRelayListTags`).
    /// Call when the user enables the toggle or on app launch.
    @MainActor
    func publishRelayList(forNpub accountNpub: String) {
        let tags = ConfigService.shared.config.publicRelayListTags
        guard !tags.isEmpty else {
            #if DEBUG
            print("NostrService: No public relays to list, skipping Kind 10002 publish")
            #endif
            return
        }

        Task {
            if let event = await signEventAsync(kind: 10002, content: "", tags: tags, signAsNpub: accountNpub) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10002 relay list for \(accountNpub.prefix(8)) with \(tags.count) relays")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10002 relay list for \(accountNpub.prefix(8))")
                #endif
            }
        }
    }

    /// Publishes Kind 10002 relay list for all accounts that have the setting enabled.
    @MainActor
    func publishRelayListsForEnabledAccounts() {
        let config = ConfigService.shared.config

        let enabledAccounts = config.publishRelayListPerAccount.filter { $0.value }.map { $0.key }
        guard !enabledAccounts.isEmpty else { return }

        Task {
            for npub in enabledAccounts {
                // Verify the account can sign
                let isOwner = npub == config.ownerNpub
                let canSign = isOwner
                    ? (!config.ownerNcryptsec.isEmpty || config.ownerHexKey != nil || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                    : (ConfigService.shared.hasCredential(forNpub: npub) || ConfigService.shared.hasBunkerConfig(forNpub: npub))
                guard canSign else { continue }

                publishRelayList(forNpub: npub)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

#if os(macOS)
/// The Mac's photo node: its own mesh node (MacFipsMeshService), which also
/// lets strangers read photos by hash through the public seeds, capped. Its
/// npub goes in the owner's 10063.
enum PhotoNode {
    /// This Mac's mesh npub while its Mesh switch is on, else nil.
    static func npub() -> String? {
        MacFipsMeshService.photoNpub().flatMap { HomeVaultLogic.meshNpub(fromInput: $0) }
    }

    /// Republish once per launch when the owner's newest 10063 lacks the photo
    /// node, so the entry appears with no setup and comes back if a stale list
    /// (another device's) dropped it.
    @MainActor static func ensureListed(in servers: [String], owner: String, nostr: NostrService) {
        guard owner == nostr.activeHexPubkey, !republished, let npub = npub() else { return }
        guard !servers.contains(where: { HomeVaultLogic.meshNpub(fromEntry: $0) == npub }) else { return }
        republished = true
        nostr.publishServerList()
    }
    @MainActor private static var republished = false
}
#endif
