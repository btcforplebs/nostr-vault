import Foundation

extension NostrEvent: ListVersionSaveEvent {}

extension NostrService {
    /// Saves a new version of the active account's `kind` list through ListVersionSave: the newest list (by
    /// the relays' agreement, as publishMergedList reads it) is kept in the vault first, the new version is
    /// stored in the vault before relays, and nothing is signed or sent when the vault didn't keep the old copy.
    /// `dTag`: for an addressable list (kinds 30000-39999), the one at that `d`. Used for the emoji list (10030)
    /// and emoji sets (30030) (RESEARCH/NV_EMOJI_LIST_HISTORY_AUDIT.md). Android twin: ListVersionSave.kt.
    @MainActor
    /// `onUndoCopyKept`: the vault has the old copy; runs before anything is signed (nuclear unfollow's
    /// "Backup saved ✓").
    func saveListVersion(kind: Int, author: String, dTag: String? = nil, verb: String,
                         onUndoCopyKept: (@MainActor () -> Void)? = nil,
                         build: (NostrEvent?) async -> ListVersionSave.Build) async -> ListVersionSave.Outcome<NostrEvent> {
        guard FileNote.isHex64(author), activeHexPubkey == author else {
            return .refused("This list belongs to another account. Switch to it first.")
        }
        let name = ListShrinkRule.name(kind)
        let steps = ListVersionSave.Steps<NostrEvent>(
            activeAccount: { [weak self] in self?.activeHexPubkey ?? "" },
            newest: { [weak self] in
                guard let self else { return .failure(.init(message: "Nothing was changed.")) }
                let alsoAsk = ListMerge.editLookupAsk(readRelays: ConfigService.shared.config.readRelays)
                let lookup = await self.lookupNewestReplaceable(kind: kind, for: author, alsoAsk: alsoAsk, dTag: dTag, skipAhead: true)
                switch ListMerge.editBase(lookup, held: nil, own: Self.ownListRelays(for: author), createdAt: { $0.created_at }) {
                case .list(let event): return .success(event)
                case .none: return .success(nil)
                case .noRelayList: return .failure(.init(message: ListMerge.noRelayListMessage))
                case .unknown:
                    return .failure(.init(message: "Not enough of your relays answered, so your newest \(name) can't be checked. Nothing was changed. Try again in a moment."))
                }
            },
            keepUndoCopy: { event in
                let kept = await VaultSocket.publish(event)
                if kept { await MainActor.run { onUndoCopyKept?() } }
                return kept
            },
            sign: { [weak self] kind, content, tags, notBefore in
                await self?.signEventAsync(kind: kind, content: content, tags: tags, signAsNpub: nil, notBefore: notBefore)
            },
            store: { await VaultSocket.publish($0) },
            send: { [weak self] in self?.postEvent($0) })
        return await ListVersionSave.save(steps, pubkey: author, kind: kind, verb: verb, build: build)
    }
}
