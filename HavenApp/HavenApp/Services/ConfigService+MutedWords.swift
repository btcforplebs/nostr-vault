import Foundation

extension ConfigService {
    /// The account whose muted words Settings shows and edits: the active
    /// one, since its key is the one that opens the private part.
    var mutedWordsAccountNpub: String {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? config.ownerNpub : active
    }

    /// Mutes `typed` for the active account, privately unless `publicly`.
    /// Android: MutedWordsViewModel.add; web: muted-words.js addMutedWord.
    @MainActor
    func muteWord(_ typed: String, publicly: Bool, done: (@MainActor (Bool) -> Void)? = nil) {
        guard let word = MutedWordsEdit.normalized(typed) else { done?(false); return }
        publishMutedWords(add: [word], publicly: publicly, done: done)
    }

    /// Takes `word` out of the active account's list, public and private.
    @MainActor
    func unmuteWord(_ word: String, done: (@MainActor (Bool) -> Void)? = nil) {
        publishMutedWords(remove: [word], publicly: false, done: done)
    }

    /// Moves `word` to the public tags (`publicly`) or the encrypted part.
    @MainActor
    func setMutedWord(_ word: String, publicly: Bool, done: (@MainActor (Bool) -> Void)? = nil) {
        publishMutedWords(add: [word], publicly: publicly, done: done)
    }

    @MainActor
    private func publishMutedWords(add: [String] = [], remove: [String] = [], publicly: Bool,
                                   done: (@MainActor (Bool) -> Void)?) {
        let npub = mutedWordsAccountNpub
        let blocks = config.blockedNpubsPerAccount[npub] ?? (npub == config.ownerNpub ? config.blacklistedNpubs : [])
        NostrService.shared.publishMutedWordsChange(for: npub, add: add, remove: remove, publicly: publicly,
                                                    localBlocks: blocks, done: done)
    }
}
