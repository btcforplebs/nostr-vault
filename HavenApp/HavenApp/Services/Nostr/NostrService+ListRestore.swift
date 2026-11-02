import Foundation

extension ListVersion {
    init(_ event: NostrEvent) {
        self.init(id: event.id, pubkey: event.pubkey, kind: event.kind, createdAt: event.created_at,
                  tags: event.tags, content: event.content)
    }
}

extension NostrService {
    /// Why a restore did not happen, in words for the person.
    enum ListRestoreError: Error {
        case refused(String)
        var message: String {
            switch self { case .refused(let text): return text }
        }
    }

    /// What a restore would change, against the newest list known right now.
    struct ListRestorePreview {
        let current: NostrEvent?
        let comeBack: Set<String>
        let go: Set<String>
    }

    /// The newest copy of `old`'s list, from the account's own relays and the
    /// vault (`vaultNewest`), with the same rule as every list edit
    /// (ListMerge.editBase): nil when there is none anywhere; an error when
    /// it can't be known, so nothing is published over a list never seen.
    func currentList(like old: ListVersion, vaultNewest: NostrEvent?) async -> Result<NostrEvent?, ListRestoreError> {
        let alsoAsk = Array(ConfigService.shared.config.readRelays.prefix(3))
        let lookup = await lookupNewestReplaceable(kind: old.kind, for: old.pubkey, alsoAsk: alsoAsk,
                                                   dTag: old.kind >= 30000 ? old.d : nil,
                                                   skipAhead: true)
        switch ListMerge.editBase(lookup, held: vaultNewest, own: Self.ownListRelays(for: old.pubkey), createdAt: { $0.created_at }) {
        case .list(let event): return .success(event)
        case .none: return .success(nil)
        case .noRelayList: return .failure(.refused(ListMerge.noRelayListMessage))
        case .unknown:
            return .failure(.refused("Not enough of your relays answered, so your newest \(ListShrinkRule.name(old.kind)) can't be checked. Nothing was changed. Try again in a moment."))
        }
    }

    /// Restores `old`, one version of the active account's list the vault
    /// kept, after the person said yes to `preview`. One rule for every list
    /// (RESEARCH/NV_LIST_PROTECTION_PLAN.md, from the PR875 review):
    /// 1. the newest list is fetched again now and must match what the person
    ///    was shown, else nothing is published;
    /// 2. the vault must hold that newest list first, so the restore can be
    ///    undone the same way; if it can't be kept there, nothing is published;
    /// 3. the old tags are signed by the same account, dated after the newest
    ///    (ListMerge.signedAt); kind 3 keeps the newest content;
    /// 4. the vault must accept it, then it goes to the person's relays;
    /// 5. the app's own copy of follows and mutes is reloaded.
    /// Never called without a tap.
    @MainActor
    /// `vaultVersions`: every version of this list the vault holds, newest first.
    func restoreList(_ old: ListVersion, shown preview: ListRestorePreview, vaultVersions: [NostrEvent]) async -> ListRestoreError? {
        let config = ConfigService.shared.config
        let npub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        guard Bech32.decode(npub)?.hexString == old.pubkey else {
            return .refused("This list belongs to another account. Switch to it first.")
        }
        let current: NostrEvent?
        switch await currentList(like: old, vaultNewest: vaultVersions.first) {
        case .failure(let error): return error
        case .success(let event): current = event
        }
        guard current?.id == preview.current?.id else {
            return .refused("Your \(ListShrinkRule.name(old.kind)) changed while this was open. Nothing was changed; look again and retry.")
        }
        if let current, current.id == old.id {
            return .refused("This version is already your newest \(ListShrinkRule.name(old.kind)).")
        }
        if let current, !vaultVersions.contains(where: { $0.id == current.id }) {
            guard await VaultSocket.publish(current) else {
                return .refused("Your vault couldn't keep a copy of your newest \(ListShrinkRule.name(old.kind)), so the restore couldn't be undone. Nothing was changed.")
            }
        }
        let (tags, content) = ListHistory.restored(old, current: current.map(ListVersion.init))
        let now = Int64(Date().timeIntervalSince1970)
        guard let signed = await signEventAsync(kind: old.kind, content: content, tags: tags, signAsNpub: npub,
                                                notBefore: ListMerge.signedAt(now: now, base: current?.created_at)),
              signed.pubkey == old.pubkey else {
            return .refused("The list couldn't be signed. Nothing was changed.")
        }
        guard await VaultSocket.publish(signed) else {
            return .refused("Your vault refused the restored \(ListShrinkRule.name(old.kind)). Nothing was sent to your relays.")
        }
        postEvent(signed)
        switch old.kind {
        case 3: await FeedService.shared.refreshContactList()
        case 10000: MuteListStore.shared.ingest(signed)
        default: break
        }
        return nil
    }}
