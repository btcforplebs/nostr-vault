import Foundation

/// One desktop Vault switch on one of the owner's public lists: relays
/// (10002), DM inbox (10050) or media servers (10063). PLANS/
/// NV_DESKTOP_VAULTS_PLAN.md §2.4 and §2.5 rule 7.
///
/// Every tap does the same three steps:
/// 1. fetch the newest list from the owner's relays;
/// 2. apply only this Vault's change to it (DesktopVaultsLists.switching);
/// 3. sign it and publish.
///
/// It never republishes a list from this device's copy, so a switch can't
/// drop a Vault entry or a hand-added relay that another device added
/// (Tron M2). When the lookup doesn't settle, nothing is signed and the
/// switch snaps back with `notLoadedMessage`. The settled rule per list is
/// the one its other editors use: 10002 and 10050 need both indexers to
/// answer (as `publishOwnerDMInbox`), 10063 goes through ListMerge.editBase
/// (as `publishServerList`).
///
/// There is no mesh relay (10002 `fipsmesh`) switch yet (Logen, 13:53Z):
/// no caller turns one on. Android twin: `DesktopVaultListEdit.kt` (P6).
enum DesktopVaultListEdit {

    enum Outcome: Equatable {
        case published
        /// The list already read that way: nothing was signed.
        case unchanged
        /// The relays couldn't say which list is newest: nothing was signed.
        case notLoaded
        /// The change would leave the list unusable: nothing was signed.
        case refused(DesktopVaultList)
        /// No signed-in account, the account changed during the lookup, or
        /// the signer said no.
        case notSigned
        /// A delete's unlist stopped part way: these lists already went out
        /// without the Vault, the rest weren't signed (Tron should-fix 5 on
        /// #2511).
        case partlyPublished([DesktopVaultList])

        /// The line the switch shows when it snaps back; nil for a change
        /// that went out or had nothing to do.
        var message: String? {
            switch self {
            case .published, .unchanged: return nil
            case .notLoaded: return DesktopVaultListEdit.notLoadedMessage
            case .refused(let list): return list.refusal
            case .notSigned: return "Your list wasn't signed, so it wasn't changed."
            case .partlyPublished(let lists):
                let names = lists.map(\.name).joined(separator: " and ")
                return "It was taken out of your \(names) list, but the rest wasn't signed."
            }
        }
    }

    static let notLoadedMessage = "Couldn't load your list, try again"

    /// Turns `vault`'s `path` switch on `list` on or off. `done` runs on the
    /// main actor once, with what happened.
    @MainActor
    static func set(_ on: Bool, vault: DesktopVault, path: DesktopVaultPath, list: DesktopVaultList,
                    nostr: NostrService = .shared, done: (@MainActor (Outcome) -> Void)? = nil) {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString.lowercased() else {
            done?(.notSigned)
            return
        }
        let signer = config.ownerNpub
        let vaults = config.desktopVaultsInEffect
        Task { @MainActor in
            guard let base = await newest(list, owner: owner, config: config, nostr: nostr) else {
                done?(.notLoaded)
                return
            }
            // Never sign one account's list as another's.
            guard Bech32.decode(ConfigService.shared.config.ownerNpub)?.hexString.lowercased() == owner else {
                done?(.notSigned)
                return
            }
            switch DesktopVaultsLists.switching(on, vault, path: path, in: list, tags: base.tags, vaults: vaults) {
            case .refused(let list):
                done?(.refused(list))
            case .tags(let tags):
                guard tags != (base.tags ?? []) else {
                    done?(.unchanged)
                    return
                }
                done?(await publish(tags, list: list, owner: owner, signer: signer, baseAt: base.createdAt, nostr: nostr))
            }
        }
    }

    /// The newest published list's tags for the switches to read (§2.1):
    /// [] when the relays agree there is none, nil when that isn't known.
    @MainActor
    static func current(_ list: DesktopVaultList, nostr: NostrService = .shared) async -> [[String]]? {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString.lowercased() else { return nil }
        guard let base = await newest(list, owner: owner, config: config, nostr: nostr) else { return nil }
        return base.tags ?? []
    }

    /// After a drag: each list whose Vault entries are now out of Desktop
    /// Vaults order is republished with only those entries moved
    /// (DesktopVaultsLists.reordered, rule 2). A list that didn't load is
    /// left as it is; `done` gets the first line worth showing, nil when all
    /// went out or had nothing to move.
    @MainActor
    static func reorder(vaults: [DesktopVault], nostr: NostrService = .shared,
                        done: (@MainActor (String?) -> Void)? = nil) {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString.lowercased() else {
            done?(Outcome.notSigned.message)
            return
        }
        Task { @MainActor in
            var line: String?
            for list in DesktopVaultList.allCases {
                guard let base = await newest(list, owner: owner, config: config, nostr: nostr) else {
                    line = line ?? notLoadedMessage
                    continue
                }
                guard let tags = base.tags else { continue }
                let moved = DesktopVaultsLists.reordered(tags, in: list, vaults: vaults)
                guard moved != tags, sameOwner(owner) else { continue }
                let outcome = await publish(moved, list: list, owner: owner, signer: config.ownerNpub,
                                            baseAt: base.createdAt, nostr: nostr)
                line = line ?? outcome.message
            }
            done?(line)
        }
    }

    /// Deleting a Vault with "Also take it out of your public lists?"
    /// answered yes (rule 5): every entry of it in all three lists, checked
    /// together, so nothing is signed when any list didn't load or one would
    /// be left unusable. `done` gets `.published` or `.unchanged` when the
    /// lists are clean and the Vault may go.
    @MainActor
    static func remove(_ vault: DesktopVault, nostr: NostrService = .shared,
                       done: @escaping @MainActor (Outcome) -> Void) {
        let config = ConfigService.shared.config
        guard let owner = Bech32.decode(config.ownerNpub)?.hexString.lowercased() else {
            done(.notSigned)
            return
        }
        Task { @MainActor in
            var lists: [DesktopVaultList: [[String]]] = [:]
            var bases: [DesktopVaultList: Int64] = [:]
            for list in DesktopVaultList.allCases {
                guard let base = await newest(list, owner: owner, config: config, nostr: nostr) else {
                    done(.notLoaded)
                    return
                }
                if let tags = base.tags { lists[list] = tags }
                if let at = base.createdAt { bases[list] = at }
            }
            switch DesktopVaultsLists.removingVault(vault, from: lists) {
            case .failure(let refusal):
                done(.refused(refusal.list))
            case .success(let changed):
                guard sameOwner(owner) else {
                    done(.notSigned)
                    return
                }
                var outcome: Outcome = .unchanged
                var sent: [DesktopVaultList] = []
                for list in DesktopVaultList.allCases {
                    guard let tags = changed[list] else { continue }
                    let one = await publish(tags, list: list, owner: owner, signer: config.ownerNpub,
                                            baseAt: bases[list], nostr: nostr)
                    if one != .published {
                        done(sent.isEmpty ? one : .partlyPublished(sent))
                        return
                    }
                    sent.append(list)
                    outcome = .published
                }
                done(outcome)
            }
        }
    }

    @MainActor
    private static func sameOwner(_ owner: String) -> Bool {
        Bech32.decode(ConfigService.shared.config.ownerNpub)?.hexString.lowercased() == owner
    }

    /// The newest published list: its tags (nil when the relays agree there
    /// is none) and its date. nil when that isn't known.
    @MainActor
    private static func newest(_ list: DesktopVaultList, owner: String, config: HavenConfig,
                               nostr: NostrService) async -> (tags: [[String]]?, createdAt: Int64?)? {
        switch list {
        case .relays, .inbox:
            let ask = list == .relays ? Array(config.readRelays.prefix(3)) + RelayDraft.indexers
                                      : config.dmInboxRelays + RelayDraft.indexers
            let lookup = await nostr.lookupNewestReplaceable(kind: list.rawValue, for: owner, alsoAsk: ask)
            // Both indexers must answer: a lagging relay's older copy, re-signed, would roll the list back.
            guard RelayDraft.settled(found: lookup.event != nil, answeredBy: lookup.answeredBy) else { return nil }
            return (lookup.event?.tags, lookup.event?.created_at)
        case .media:
            let lookup = await nostr.lookupNewestReplaceable(kind: 10063, for: owner,
                                                             alsoAsk: [RelayConfiguration.serverListIndexerRelay],
                                                             skipAhead: true)
            switch ListMerge.editBase(lookup, held: nil, own: NostrService.ownListRelays(for: owner),
                                      createdAt: { $0.created_at }) {
            case .list(let event): return (event.tags, event.created_at)
            case .none: return (nil, nil)
            case .unknown, .noRelayList: return nil
            }
        }
    }

    @MainActor
    private static func publish(_ tags: [[String]], list: DesktopVaultList, owner: String, signer: String,
                                baseAt: Int64?, nostr: NostrService) async -> Outcome {
        let notBefore = baseAt.map { ListMerge.signedAt(now: Int64(Date().timeIntervalSince1970), base: $0) }
        let out = list == .relays ? tags : tags.filter { $0.count < 2 || !NostrService.isLoopbackRelay($0[1]) }
        // Each kind spelled out, for the list sign guard (UserListSignGuardTests).
        let signed: NostrEvent?
        switch list {
        case .relays: signed = await nostr.signEventAsync(kind: 10002, content: "", tags: out, signAsNpub: signer, notBefore: notBefore)
        case .inbox: signed = await nostr.signEventAsync(kind: 10050, content: "", tags: out, signAsNpub: signer, notBefore: notBefore)
        case .media: signed = await nostr.signEventAsync(kind: 10063, content: "", tags: out, signAsNpub: signer, notBefore: notBefore)
        }
        guard let event = signed, event.pubkey.lowercased() == owner else { return .notSigned }
        switch list {
        case .relays:
            nostr.noteOwnRelayList(event)
        case .inbox:
            break
        case .media:
            // Ours is now the newest: Media Servers merges from it next time.
            if nostr.acceptServerListStamp(pubkey: event.pubkey, createdAt: event.created_at, id: event.id,
                                           signedByAuthor: true) {
                nostr.serverLists[event.pubkey] = ProfileRepository.parseServerListTags(event.tags)
            }
        }
        nostr.postEvent(event)
        return .published
    }
}
