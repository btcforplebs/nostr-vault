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

    /// Whether a Delete everywhere sends this device's `/files` kind 5: only
    /// when the home vault itself took the delete. A mirror or another device
    /// taking it while the vault keeps the blob would empty the room of notes
    /// for a file still there (Tron, PR 1990). The vault sends its own kind 5
    /// for a blob it deletes (haven-go filesBlobGone). `deleted`: the delete
    /// report's keys (`MeshDeleteTarget.key` for mesh devices).
    static func homeVaultTookDelete(homeVaultNpub: String?, deleted: [String]) -> Bool {
        guard let home = homeVaultNpub, !home.isEmpty else { return false }
        return deleted.contains(MeshDeleteTarget(npub: home, name: "").key)
    }

    /// What the vault's `/files` answer to a file note means (plan gap 1):
    /// accepted or `duplicate:` is done, `restricted:` (this device unpaired,
    /// or a key the room never takes) is dropped, anything else waits.
    static func fileNoteOutcome(accepted: Bool, message: String) -> HomeVaultSendResult {
        if accepted || message.hasPrefix("duplicate:") { return .sent }
        if message.hasPrefix("restricted:") { return .rejected(message) }
        return .unreachable(message.isEmpty ? "the vault did not take the note" : message)
    }

    /// The servers a file note names after an upload: the configured ones,
    /// the one that served it (`hosted`, matched by host) first. A server
    /// may answer with a CDN host, so the note names the configured address.
    static func fileNoteServers(configured: [String], hosted: URL?) -> [String] {
        guard let host = hosted?.host?.lowercased(),
              let first = configured.firstIndex(where: { URL(string: $0)?.host?.lowercased() == host }) else { return configured }
        var ordered = configured
        ordered.insert(ordered.remove(at: first), at: 0)
        return ordered
    }
}
