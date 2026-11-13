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
    /// More tags for an add, such as an emoji copy's (EmojiNote.tags). nil
    /// for a plain note; optional so queues saved before it still read.
    var extraTags: [[String]]? = nil
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

    /// Whether sending this item may ask the account's signer (and so a
    /// person, with a bunker). Notes are signed already; a file note and a
    /// blob over the mesh sign with this device's mesh key. Only a mirror to
    /// a media server, or a blob the vault passes on to a public server (its
    /// forward token), needs the account.
    static func asksAccountSigner(_ item: HomeVaultItem) -> Bool {
        switch item.kind {
        case .mirror: return true
        case .blob: return item.server.map(isPublicServer) ?? false
        default: return false
        }
    }

    /// Whether a blob over the mesh may fall back to the owner's upload form
    /// (no mesh key yet, or an older vault that turns the device form down).
    /// Only with the account key on this device: a bunker or other remote
    /// signer is never asked for a mesh send.
    static func meshBlobMayUseOwnerForm(signingMode: String) -> Bool {
        signingMode == "local"
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

    /// The servers a Media tab save's file note names (Magic Paste, photo
    /// picker, Files): the configured ones that took it, in configured order.
    /// None took it: an empty list, which means the vault holds it, when this
    /// is the vault (the Mac) or the home vault was given it. nil: nowhere
    /// the owner's other devices can fetch it, so no note.
    static func mediaSaveNoteServers(configured: [String], accepted: [String], toHomeVault: Bool, isVault: Bool) -> [String]? {
        let took = configured.filter(accepted.contains)
        if !took.isEmpty { return took }
        return toHomeVault || isVault ? [] : nil
    }
}
