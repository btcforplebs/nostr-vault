import Foundation

/// Telling the owner's `/files` room about an upload or a delete
/// (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md gap 1), so every open Media tab
/// shows it. Signed with this device's mesh key only, at send time.
///
/// - iPhone/iPad: queued on `HomeVaultSender`'s fileNote lane for the media
///   vault, sent when the mesh reaches it.
/// - Mac: it is the vault, so the note goes straight to its own relay on
///   loopback (signed with its own mesh key, which the room takes as self).
///   No kind 5 from here: the vault sends its own when it deletes a blob
///   (haven-go filesBlobGone).
@MainActor
enum FileNotesOutbox {
    /// `sha256` was uploaded by the active account; `servers`: the media
    /// servers that have it, the one serving it first (none = the vault).
    static func uploaded(sha256: String, mime: String, size: Int, servers: [String]) {
        let draft = FileNoteDraft(action: .add, sha256: sha256.lowercased(), mime: mime, size: Int64(size), servers: servers)
        #if os(iOS)
        HomeVaultSender.shared.offerFileNote(draft)
        #else
        guard let owner = ownOwner() else { return }
        Task { _ = await FileNotesTransport.send(draft, owner: owner, url: ownFilesURL(), vaultNpub: nil) }
        #endif
    }

    /// A Delete everywhere finished; `deleted`: the report's keys. The kind 5
    /// goes only when the home vault itself took it (Tron, PR 1990).
    static func deletedEverywhere(sha256: String, deleted: [String]) {
        #if os(iOS)
        guard HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: HomeVaultSender.shared.mediaVault?.meshNpub,
                                                 deleted: deleted) else { return }
        HomeVaultSender.shared.offerFileNote(FileNoteDraft(action: .delete, sha256: sha256.lowercased(),
                                                           mime: "application/octet-stream", size: 0, servers: []))
        #endif
    }

    #if os(macOS)
    private static func ownOwner() -> String? {
        let active = NostrService.shared.activeHexPubkey
        guard Bech32.decode(ConfigService.shared.config.ownerNpub)?.hexString.lowercased() == active,
              FileNote.isHex64(active) else { return nil }
        return active
    }

    private static func ownFilesURL() -> URL? {
        URL(string: ConfigService.shared.config.nostrURL).flatMap(FileNote.filesURL(base:))
    }
    #endif
}

/// The wire side of one file note, free of app state: an add signs one 1063;
/// a delete AUTHs, asks `#x` for every note naming the blob, and signs one
/// kind 5 for them all (none left is done). The twin of Android's
/// `HomeVaultSender.sendFileNote`.
enum FileNotesTransport {
    static func send(_ draft: FileNoteDraft, owner: String, url: URL?, vaultNpub: String?) async -> HomeVaultSendResult {
        guard let url else { return .rejected("no /files address") }
        let socket = FilesSocket(url: url, vaultNpub: vaultNpub)
        defer { socket.close() }
        let kind: Int
        let tags: [[String]]
        switch draft.action {
        case .add:
            guard let note = FileNote.tags(sha256: draft.sha256, mime: draft.mime, size: draft.size,
                                           owner: owner, servers: draft.servers) else { return .rejected("not a note the vault takes") }
            // Writes need no AUTH; the room asks anyway, so answer it.
            _ = await socket.auth()
            (kind, tags) = (FileNote.kind, note)
        case .delete:
            guard FileNote.isHex64(draft.sha256), FileNote.isHex64(owner) else { return .rejected("bad hash") }
            guard await socket.auth() else { return .unreachable("/files did not take this device's AUTH") }
            let filter: [String: Any] = ["kinds": [FileNote.kind], "#x": [draft.sha256], "#p": [owner]]
            guard let found = await socket.query(subId: "files-del", filter: filter) else {
                return .unreachable("/files did not answer")
            }
            let ids = found.compactMap { FileNote.parse($0) }.filter { $0.sha256 == draft.sha256 }.map(\.id)
            // Nothing names it: nothing to take back.
            guard let deletion = FileNoteDeletion.tags(noteIDs: ids, sha256: draft.sha256, owner: owner) else { return .sent }
            (kind, tags) = (FileNote.deletionKind, deletion)
        }
        // No mesh key yet (the engine makes it): later, never the owner's signer.
        guard let signed = MeshKeySigner.fileNotes(kind: kind, tags: tags) else { return .unreachable("no mesh key yet") }
        guard let answer = await socket.publish(signed) else { return .unreachable("/files did not confirm") }
        if !answer.accepted { print("FileNotes: /files refused a \(draft.action.rawValue) for \(draft.sha256.prefix(8)): \(answer.message)") }
        return HomeVaultLogic.fileNoteOutcome(accepted: answer.accepted, message: answer.message)
    }
}
