import Foundation

/// Drafts deleted on this device, kept on disk (Mac bug hunt 2026-11-05):
/// the relay copy of a posted or deleted draft used to come back on the next
/// fetch, because nothing remembered the delete. The relay's kind 5 can be
/// missed (the vault was down, the app quit before it went, a fetch landed
/// first), so a relay copy no newer than the delete is left out, and the
/// delete is sent again.
///
/// Pure Foundation so MediaLogicTests can test it.
struct DraftTombstones: Codable, Equatable {
    /// Draft id → when it was deleted here.
    private(set) var deletedAt: [String: Date] = [:]

    /// How long a delete is remembered: long enough for any queued kind 5 to
    /// reach the vault.
    static let keep: TimeInterval = 90 * 24 * 3600

    mutating func record(id: String, at date: Date) {
        deletedAt[id] = max(date, deletedAt[id] ?? .distantPast)
    }

    /// A copy saved at `updatedAt` is the deleted draft (not a later save
    /// under the same id).
    func hides(id: String, updatedAt: Date) -> Bool {
        guard let deleted = deletedAt[id] else { return false }
        return updatedAt <= deleted
    }

    mutating func forget(id: String) {
        deletedAt[id] = nil
    }

    mutating func prune(now: Date) {
        deletedAt = deletedAt.filter { now.timeIntervalSince($0.value) < Self.keep }
    }
}
