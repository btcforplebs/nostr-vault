import Foundation

/// Keeps one article, recipe or poll composer's draft on disk while it is
/// edited: a short pause after each change saves it, closing the sheet saves
/// it, publishing or discarding removes it. The draft belongs to the account
/// that opened the composer, even if another one becomes active meanwhile.
@MainActor
final class ComposerDraftKeeper: ObservableObject {
    let kind: ComposerDraft.Kind
    let account: String
    private let store: ComposerDraftStore

    /// The draft being edited, once it has been saved or picked from the list.
    private(set) var draftId: String?
    private var lastSaved: ComposerDraft?
    private var lastCover: Data?
    private var pending: Task<Void, Never>?
    /// Set after publish or discard, so a late autosave or the sheet's
    /// disappearance cannot bring the draft back.
    private var finished = false

    /// The other saved drafts of this kind, for the "saved drafts" row.
    @Published private(set) var others: [ComposerDraft] = []

    init(kind: ComposerDraft.Kind, account: String? = nil, store: ComposerDraftStore = .shared) {
        self.kind = kind
        self.account = account ?? ConfigService.shared.activeAccountHexPubkey
        self.store = store
        refreshOthers()
    }

    /// Saves after a short pause, so typing writes once per pause, not per key.
    func changed(_ draft: ComposerDraft, cover: Data?) {
        pending?.cancel()
        guard !finished else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow(draft, cover: cover)
        }
    }

    /// Writes the draft now if it differs from what is on disk.
    func saveNow(_ draft: ComposerDraft, cover: Data?) {
        pending?.cancel()
        guard !finished else { return }
        guard draft.hasContent || cover != nil || draftId != nil else { return }
        var stamped = draft
        stamped.id = draftId ?? UUID().uuidString
        stamped.hasCover = cover != nil
        if let lastSaved, lastSaved.sameContent(as: stamped), lastCover == cover { return }
        stamped.updatedAt = Date()
        store.save(stamped, cover: cover, account: account)
        draftId = stamped.id
        lastSaved = stamped
        lastCover = cover
    }

    /// Switches the composer to a saved draft. Returns its cover photo.
    func open(_ draft: ComposerDraft) -> Data? {
        pending?.cancel()
        let cover = store.cover(for: draft, account: account)
        draftId = draft.id
        lastSaved = draft
        lastCover = cover
        refreshOthers()
        return cover
    }

    func delete(_ draft: ComposerDraft) {
        store.delete(id: draft.id, account: account)
        refreshOthers()
    }

    /// The user chose Discard, or the post went out: drop the draft.
    func finish() {
        pending?.cancel()
        finished = true
        if let draftId { store.delete(id: draftId, account: account) }
    }

    func refreshOthers() {
        others = store.drafts(kind, account: account).filter { $0.id != draftId }
    }
}
