import Foundation

/// Kind-0 profiles parsed but not yet written to `NostrService.profiles`.
/// Each write to that `@Published` dictionary redraws every screen that
/// watches the service, hidden tabs included, so a burst of profiles (the
/// globe's faces, a feed page) is written in one go: one redraw for the
/// batch, not one per profile (iPhone heat, 10/21).
struct ProfileWriteBatch {
    private(set) var pending: [String: FeedProfile] = [:]

    var isEmpty: Bool { pending.isEmpty }

    /// What a new kind 0 for `pubkey` is compared with: the one waiting
    /// here, else the one stored.
    func current(_ pubkey: String, stored: [String: FeedProfile]) -> FeedProfile? {
        pending[pubkey] ?? stored[pubkey]
    }

    mutating func add(_ profile: FeedProfile) {
        pending[profile.pubkey] = profile
    }

    /// Writes every waiting profile into `profiles` with one assignment and
    /// returns whose changed. A profile written there directly since it was
    /// parsed from a newer kind 0 is kept.
    mutating func flush(into profiles: inout [String: FeedProfile]) -> [String] {
        guard !pending.isEmpty else { return [] }
        var next = profiles
        var written: [String] = []
        for (pubkey, profile) in pending {
            if let stored = next[pubkey]?.metadataCreatedAt, let mine = profile.metadataCreatedAt, stored > mine { continue }
            next[pubkey] = profile
            written.append(pubkey)
        }
        pending.removeAll(keepingCapacity: true)
        if !written.isEmpty { profiles = next }
        return written
    }
}
