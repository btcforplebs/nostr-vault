import Foundation

extension NostrService {
    /// Saves a merged list (List backups › Merge) after the person's Save
    /// tap. The restore rules (restoreList) plus the merge's own: the result
    /// is never empty; a base whose private part wasn't read is refused (the
    /// new event replaces that part, and entries never read would be wiped);
    /// private entries are encrypted to the account again. Twin of web
    /// `net/list-merge-save.js`.
    /// `base`: the current list the merge was built on (nil: there was none);
    /// `vaultVersions`: every version of this list the vault holds, newest first.
    @MainActor
    func saveMergedList(kind: Int, base: ListVersionMerge.Opened?, tags: [[String]], privateTags: [[String]],
                        vaultVersions: [NostrEvent]) async -> ListRestoreError? {
        let name = ListShrinkRule.name(kind)
        guard ListVersionMerge.canMerge(kind) else { return .refused("This list can't be merged here.") }
        let entries = tags.filter { $0.first.map { !ListShrinkRule.metadataTags.contains($0) } ?? false }
        guard !entries.isEmpty || !privateTags.isEmpty else {
            return .refused("The merged \(name) would be empty. Nothing was changed.")
        }
        if let base, ListVersionMerge.hasPrivate(base.version), base.unread {
            return .refused("The private part of your \(name) couldn't be opened, so saving would wipe it. Nothing was changed.")
        }
        let npub = Self.restoreAccountNpub()
        guard let me = Bech32.decode(npub)?.hexString, base == nil || base?.version.pubkey == me else {
            return .refused("This list belongs to another account. Switch to it first.")
        }
        let like = ListVersion(id: "", pubkey: me, kind: kind, createdAt: 0, tags: [], content: "")
        let current: NostrEvent?
        switch await currentList(like: like, vaultNewest: vaultVersions.first) {
        case .failure(let error): return error
        case .success(let event): current = event
        }
        guard current?.id == base?.version.id else {
            return .refused("Your \(name) changed while this was open. Nothing was changed; look again and retry.")
        }
        if let current, !vaultVersions.contains(where: { $0.id == current.id }) {
            guard await VaultSocket.publish(current) else {
                return .refused("Your vault couldn't keep a copy of your \(name) first, so the merge couldn't be undone. Nothing was changed.")
            }
        }
        var content = ""
        if kind == 3 {
            content = current?.content ?? ""
        } else if !privateTags.isEmpty {
            guard let data = try? JSONSerialization.data(withJSONObject: privateTags),
                  let json = String(data: data, encoding: .utf8),
                  let sealed = try? await MuteListStore.encryptToSelf(json, me: me, nip04: false) else {
                return .refused("Your private entries couldn't be encrypted. Nothing was changed.")
            }
            content = sealed
        }
        let now = Int64(Date().timeIntervalSince1970)
        guard let signed = await signEventAsync(kind: kind, content: content, tags: tags, signAsNpub: npub,
                                                notBefore: ListMerge.signedAt(now: now, base: current?.created_at)),
              signed.pubkey == me else {
            return .refused("The list couldn't be signed. Nothing was changed.")
        }
        guard Self.restoreAccountNpub() == npub else {
            return .refused("You switched accounts during the merge. Nothing was changed.")
        }
        guard await VaultSocket.publish(signed) else {
            return .refused("Your vault refused the merged \(name). Nothing was sent to your relays.")
        }
        guard Self.restoreAccountNpub() == npub else {
            return .refused("You switched accounts during the merge. Your vault kept the merged list; this app didn't send it to your relays. Switch back and check it.")
        }
        postEvent(signed)
        switch kind {
        case 3: await FeedService.shared.refreshContactList()
        case 10000: MuteListStore.shared.ingest(signed)
        default: break
        }
        return nil
    }
}
