import Foundation

extension NostrService {
    /// Adds the servers on the owner's published media server list (kind
    /// 10063, set in another app) to this device's upload servers. See
    /// `ServerListAdoption`. Nothing is published here. Twin of Android's
    /// `syncOwnerServerList`.
    @MainActor
    func syncOwnerServerList() async {
        let configService = ConfigService.shared
        let config = configService.config
        guard !config.ownerNpub.isEmpty,
              let owner = Bech32.decode(config.ownerNpub)?.hexString else { return }

        let lookup = await lookupNewestReplaceable(
            kind: 10063, for: owner,
            alsoAsk: [RelayConfiguration.serverListIndexerRelay] + config.feedRelays)
        guard let newest = lookup.event else { return }
        // lookupNewestReplaceable keeps only events whose author and signature it checked.
        let published = ProfileRepository.parseServerListTags(newest.tags)
        if acceptServerListStamp(pubkey: owner, createdAt: newest.created_at, id: newest.id, signedByAuthor: true) {
            serverLists[owner] = published
        }

        let current = configService.config
        let own = [current.macRelayHttpsURL].filter { !$0.isEmpty }
        guard let result = ServerListAdoption.adopt(
            local: current.blossomMirrors,
            updatedAt: current.blossomMirrorsUpdatedAt,
            published: published.filter { !HavenConfig.isDefunctMirror($0) },
            publishedAt: newest.created_at,
            base: Self.serverListManaged(owner: owner),
            ownServers: own
        ) else { return }
        configService.config.blossomMirrors = result.mirrors
        configService.config.blossomMirrorsUpdatedAt = result.updatedAt
        configService.save()
        #if DEBUG
        if !result.added.isEmpty {
            print("NostrService: Adopted \(result.added.count) media server(s) from the published kind 10063")
        }
        #endif
    }
}
