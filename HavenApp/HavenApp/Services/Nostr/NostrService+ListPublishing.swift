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

        let tags = hexKeys.map { ["p", $0] }

        Task {
            if let event = await signEventAsync(kind: 10000, content: "", tags: tags, signAsNpub: accountNpub) {
                postEvent(event)
                ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
                ConfigService.shared.save()
                #if DEBUG
                print("NostrService: Successfully published Kind 10000 mute list with \(tags.count) tags for \(accountNpub.prefix(8))")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10000 mute list for \(accountNpub.prefix(8))")
                #endif
            }
        }
    }

    /// BUD-03: Publishes a Kind 10063 (User Server List) event advertising Blossom mirrors.
    /// Call whenever blossomMirrors changes (settings, setup wizard).
    /// Pass fipsDetectedNpub when available to include the detected .fips address.
    @MainActor
    func publishServerList(fipsDetectedNpub: String? = nil) {
        let mirrors = ConfigService.shared.config.activeBlossomMirrors(detectedNpub: fipsDetectedNpub)
        guard !mirrors.isEmpty else {
            #if DEBUG
            print("NostrService: No Blossom mirrors configured, skipping Kind 10063 publish")
            #endif
            return
        }

        // Build ["server", url] tags — ordered by reliability (local relay first via activeBlossomMirrors)
        let tags = mirrors.map { ["server", $0] }

        Task {
            if let event = await signEventAsync(kind: 10063, content: "", tags: tags) {
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
    /// relays set to Never connect. Public `relay` tags, empty content. An
    /// empty list is published too, so unblocking the last relay clears it.
    func publishBlockedRelayList() {
        let config = ConfigService.shared.config
        let tags = config.blockedRelays.map { ["relay", HavenConfig.normalizedRelayURL($0)] }
        Task {
            if let event = await signEventAsync(kind: 10006, content: "", tags: tags, signAsNpub: config.ownerNpub) {
                postEvent(event)
                #if DEBUG
                print("NostrService: Published Kind 10006 blocked relay list with \(tags.count) relays")
                #endif
            } else {
                #if DEBUG
                print("NostrService: Failed to sign Kind 10006 blocked relay list")
                #endif
            }
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

        let newest = await fetchNewestDMRelayList(for: ownerHex, alsoAsk: config.dmInboxRelays)
        let published = newest?.relays.filter { !Self.isLoopbackRelay($0) }

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
