import Foundation

extension NostrService {
    /// Mutes (`add`) or unmutes (`remove`) words on `accountNpub`'s kind
    /// 10000, built on the newest list the way blocks are
    /// (`muteListEditBase`): only those `word` entries change, everything else
    /// on the list is kept. `publicly`: `add` goes in the public tags, else in
    /// the encrypted part (the default: a public list says what upsets you).
    /// Nothing is kept on this device first: the words show once the
    /// published list is read back. Calls `done` with whether it was
    /// published; when it wasn't, the person is told why.
    /// Android: NostrServiceMutedWords.kt; web: muted-words.js.
    @MainActor
    func publishMutedWordsChange(for accountNpub: String, add: [String] = [], remove: [String] = [],
                                 publicly: Bool, localBlocks: [String], done: (@MainActor (Bool) -> Void)? = nil) {
        guard let author = Bech32.decode(accountNpub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString else {
            done?(false); return
        }
        let notSaved = add.isEmpty ? "Muted word not removed" : "Muted word not saved"
        let blocks = localBlocks.compactMap { Bech32.decode($0.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString }
        let fail: (String) -> Void = { message in
            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: message, tone: .error)
            done?(false)
        }

        Task {
            guard let start = await muteListEditBase(author: author, localBlocks: blocks, notSaved: notSaved) else {
                done?(false); return
            }
            let known = MuteListStore.shared.list(forHex: author).privateWords
            let edit = await MutedWordsEdit.apply(
                tags: start.base.tags, content: start.base.content, add: add, remove: remove,
                publicly: publicly, knownPrivate: known,
                decrypt: { try await MuteListStore.decryptToSelf($0, me: author, nip04: $1) },
                encrypt: { try await MuteListStore.encryptToSelf($0, me: author, nip04: $1) })
            let result: MutedWordsEdit.Result
            switch edit {
            case .success(let r): result = r
            case .failure(.nothingToDo): done?(false); return
            case .failure(.privatePart):
                fail("\(notSaved): your private muted words couldn't be updated. Is your signer connected?")
                return
            }
            guard let event = await signEventAsync(
                kind: 10000, content: result.content, tags: result.tags, signAsNpub: accountNpub,
                notBefore: start.baseAt.map { ListMerge.signedAt(now: Int64(Date().timeIntervalSince1970), base: $0) }) else {
                fail("\(notSaved): your signer didn't answer")
                return
            }
            postEvent(event)
            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
            ConfigService.shared.save()
            applyOwnMuteList(event)
            #if DEBUG
            print("NostrService: Published Kind 10000 (muted words) with \(result.tags.count) tags for \(author.prefix(8))")
            #endif
            done?(true)
        }
    }
}
