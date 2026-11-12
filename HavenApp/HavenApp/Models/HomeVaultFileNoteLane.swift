import Foundation

/// The fileNote lane of the home-vault queue (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md
/// gap 1): what to tell the vault's /files about one blob. The note is signed
/// with this device's mesh key when it is sent, never when queued, so an
/// unpair or a new key in between never ships a stale signature.
struct FileNoteDraft: Codable, Equatable {
    enum Action: String, Codable { case add, delete }
    var action: Action
    var sha256: String
    var mime: String
    var size: Int64
    /// The media servers that have it (add only); empty = the vault holds it.
    var servers: [String]
}

extension HomeVaultLogic {
    /// A queue item for one blob's note on the home vault's lane.
    static func fileNoteItem(_ draft: FileNoteDraft, owner: String, now: Date = Date()) -> HomeVaultItem {
        HomeVaultItem(kind: .fileNote, id: draft.sha256.lowercased(), ownerHex: owner, eventJSON: nil,
                      contentType: draft.mime, added: now, attempts: 0, notBefore: nil, fileNote: draft)
    }

    /// `queue` with `item` in it: one fileNote item per blob, the newest
    /// word winning (a delete takes back a waiting add, and the other way).
    static func addingFileNote(_ item: HomeVaultItem, to queue: [HomeVaultItem]) -> [HomeVaultItem] {
        guard item.kind == .fileNote else { return queue + [item] }
        if let same = queue.first(where: { sameSend($0, item) }), same.fileNote?.action == item.fileNote?.action {
            return queue
        }
        return queue.filter { !sameSend($0, item) } + [item]
    }

    /// Whether sending this kind may need the account's signer (and so a
    /// person, with a bunker). Notes are signed already; a file note signs
    /// with the device's mesh key.
    static func needsAccountSigner(_ kind: HomeVaultItem.Kind) -> Bool {
        kind == .blob || kind == .mirror
    }
}
