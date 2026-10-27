import Foundation

/// The app's side of `NotificationReadiness`: holds an alert back until its
/// note, and its author's name and picture, can draw.
extension LocalNotificationService {
    /// Waits, bounded, until the note behind a `type` alert and its author can
    /// show on screen. Returns the note lookup (`carriedNotes`), retried while
    /// the relay has not answered with the event, so the alert carries it.
    static func awaitRenderable(type: String, id: String, author: String,
                                carried initial: [String: String] = [:]) async -> [String: String] {
        let needs = NotificationReadiness.needs(type: type)
        var carried = initial

        // Start the author fetches first so they run while the note is read.
        if needs.profile { requestProfile(author) }

        if needs.note, carried[NotificationNote.eventKey] == nil {
            _ = await NotificationReadiness.wait(timeout: NotificationReadiness.noteTimeout) {
                carried = await carriedNotes(type: type, id: id)
                return carried[NotificationNote.eventKey] != nil
            }
        }
        if needs.profile { await awaitAuthor(author, avatar: needs.avatar) }
        return carried
    }

    /// Waits for `pubkey`'s profile and, when `avatar`, its picture in the
    /// avatar cache, so the list, pill and badge name a person the app can draw.
    static func awaitAuthor(_ pubkey: String, avatar: Bool = true) async {
        guard NotificationPolicy.isPubkeyHex(pubkey) else { return }
        let nostr = NostrService.shared
        requestProfile(pubkey)
        let hasProfile = await NotificationReadiness.wait(timeout: NotificationReadiness.profileTimeout) {
            nostr.profiles[pubkey] != nil
        }
        guard hasProfile, avatar, let url = nostr.profiles[pubkey]?.pictureURL else { return }
        await warmAvatar(url)
    }

    private static func requestProfile(_ pubkey: String) {
        guard NotificationPolicy.isPubkeyHex(pubkey),
              NostrService.shared.profiles[pubkey] == nil else { return }
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
    }

    /// Loads the picture into the cache the avatar views read, giving up after
    /// `NotificationReadiness.avatarTimeout`.
    private static func warmAvatar(_ url: URL) async {
        if AvatarImageCache.shared.image(for: url) != nil { return }
        AvatarImageCache.shared.load(url: url) { _ in }
        _ = await NotificationReadiness.wait(timeout: NotificationReadiness.avatarTimeout) {
            AvatarImageCache.shared.image(for: url) != nil || MediaCacheService.shared.isKnown404(url: url)
        }
    }
}
