import Foundation

/// Whether the full-screen viewer offers Delete for a file.
///
/// Delete signs a Blossom delete with the active account's key, so it is
/// only offered for that account's own media: the note the file came from
/// was posted by the active account. A screen that brings its own delete
/// (the Media page) has already decided the file is yours. Anything else,
/// including a file whose poster is unknown, gets no Delete.
enum MediaDeleteGate {
    static func showsDelete(screenOwnsDelete: Bool, poster: String?, activePubkey: String) -> Bool {
        if screenOwnsDelete { return true }
        let me = activePubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let poster = poster?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !poster.isEmpty, !me.isEmpty else { return false }
        return poster == me
    }
}
