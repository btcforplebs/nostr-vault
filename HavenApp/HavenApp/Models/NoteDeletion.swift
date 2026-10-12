import Foundation

/// Deleting one of your posts: the NIP-09 request that asks relays to drop
/// it, and the local list without it. The app's own copy in
/// `NostrService.events` used to survive a delete until the next reload, so
/// the Posts and Media lists kept showing a post that was gone.
/// Twin: Android `NoteDeletion`.
enum NoteDeletion {
    /// A kind-5 request for one post.
    static func requestTags(noteId: String) -> [[String]] { [["e", noteId]] }

    /// `events` without the deleted post. Nothing else moves.
    static func without<Event: Identifiable>(_ events: [Event], noteId: Event.ID) -> [Event] {
        events.filter { $0.id != noteId }
    }
}
