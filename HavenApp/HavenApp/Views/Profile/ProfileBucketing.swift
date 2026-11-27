import Foundation

/// Splits a profile's notes into its tabs through the one gate (`WebGate`,
/// RESEARCH/NV_ONE_WOT_GATE.md §3). Pure, so it can be unit tested; the
/// loader calls it once per change to the notes, never from `body`.
///
/// - The profile owner's own notes are theirs to show: Notes and Media are
///   never judged.
/// - Replies and reposts also show other people (the post answered, the
///   post reposted): a row that shows someone blocked, or that the mute
///   list hides, goes.
/// - Tagged notes are written by other people, so each is judged on its
///   signer: blocked goes, inside your web shows, the rest wait behind the
///   "from outside your web" fold and are not counted.
enum ProfileBucketing {
    static func buckets(notes: [FeedNote], tagged: [FeedNote], owner: String, gate: WebGate.Web,
                        authorOf: (String) -> String?) -> ProfileNoteBuckets {
        // Opening a blocked person's profile is a choice: their own rows
        // stay, only the other people a row shows are checked.
        var rowGate = gate
        rowGate.blocked.remove(owner.lowercased())
        func hidden(_ note: FeedNote) -> Bool {
            WebGate.isBlocked(.feed(note, authorOf: authorOf), in: rowGate)
        }

        var out = ProfileNoteBuckets()
        for note in notes {
            if note.kind == 6 {
                // A repost is the reposter's: someone else's repost of this
                // person's post is not one of theirs.
                guard (note.repostedBy ?? note.pubkey) == owner, !hidden(note) else { continue }
                out.reposts.append(note)
                continue
            }
            if note.kind == 30023 { continue }
            if note.isReply {
                // Its picture goes with it: Media must not show a hidden reply.
                guard !hidden(note) else { continue }
                out.replies.append(note)
            } else {
                out.top.append(note)
            }
            if !note.mediaURLs.isEmpty { out.media.append(note) }
        }
        for note in tagged where note.pubkey != owner {
            switch WebGate.judge(.feed(note, authorOf: authorOf), in: gate) {
            case .blocked: continue
            case .inside: out.tagged.append(note)
            case .loose, .outside: out.taggedOutside.append(note)
            }
        }
        return out
    }
}

/// The profile's notes split by tab.
struct ProfileNoteBuckets {
    var top: [FeedNote] = []
    var media: [FeedNote] = []
    var replies: [FeedNote] = []
    var reposts: [FeedNote] = []
    /// Tagged notes from inside your web: the tab's list and its count.
    var tagged: [FeedNote] = []
    /// Tagged notes from outside your web, behind the fold and not counted.
    var taggedOutside: [FeedNote] = []
}
