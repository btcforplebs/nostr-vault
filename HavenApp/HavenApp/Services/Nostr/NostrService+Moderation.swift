import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// Reports an event using Kind 1984
    /// - Parameters:
    ///   - eventId: The ID of the event being reported
    ///   - pubkey: The pubkey of the event author
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportEvent(eventId: String, pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["e", eventId, "", "report"],
            ["p", pubkey]
        ]

        // Add reason-specific tag if provided
        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        Task {
            guard let signed = await signEventAsync(kind: 1984, content: description ?? "Reported for \(reason)", tags: tags) else {
                #if DEBUG
                print("NostrService: Failed to sign reporting event")
                #endif
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 1984 report for event \(eventId)")
            #endif
        }
    }

    /// Reports a user using Kind 1984
    /// - Parameters:
    ///   - pubkey: The pubkey of the user being reported
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportUser(pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["p", pubkey]
        ]

        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        Task {
            guard let signed = await signEventAsync(kind: 1984, content: description ?? "Reported user for \(reason)", tags: tags) else {
                #if DEBUG
                print("NostrService: Failed to sign user reporting event")
                #endif
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 1984 report for user \(pubkey)")
            #endif
        }
    }

    /// Publishes a NIP-09 deletion request (kind 5) for the given event ID,
    /// then drops the post from `events` so your Posts and Media lists stop
    /// showing it before the next reload. Signing failures leave the list
    /// alone, like `deleteOwnEvents`.
    func deleteNote(id: String) {
        Task {
            guard let signed = await signEventAsync(kind: 5, content: "", tags: NoteDeletion.requestTags(noteId: id)) else {
                #if DEBUG
                print("NostrService: Failed to sign deletion event")
                #endif
                return
            }
            postEvent(signed)
            #if DEBUG
            print("NostrService: Posted Kind 5 deletion request for event \(id)")
            #endif
            events = NoteDeletion.without(events, noteId: id)
            eventUpdateSubject.send()
            NotificationCenter.default.post(name: .havenOwnEventsDeleted, object: Set([id]))
        }
    }

    /// Your own loaded posts that link the blob `sha256`, in their text or
    /// tags (imeta). These are the posts whose media the Media tab shows.
    func ownEvents(referencingBlob sha256: String) -> [NostrEvent] {
        let owner = activeHexPubkey
        let hash = sha256.lowercased()
        guard !owner.isEmpty, hash.count == 64 else { return [] }
        return events.filter { event in
            event.pubkey == owner && Self.blobPostKinds.contains(event.kind) && (
                event.content.lowercased().contains(hash)
                || event.tags.contains { $0.contains { $0.lowercased().contains(hash) } }
            )
        }
    }

    /// Asks relays to delete your posts that link `sha256` (one NIP-09
    /// request naming them all), and drops them and their media here so the
    /// Media tab stops showing a tile for a file that is gone.
    /// - Returns: how many posts the request named, 0 if signing failed.
    @discardableResult
    func deleteOwnEvents(referencingBlob sha256: String) async -> Int {
        let targets = ownEvents(referencingBlob: sha256)
        guard !targets.isEmpty else { return 0 }
        var tags = targets.map { ["e", $0.id] }
        for kind in Set(targets.map(\.kind)).sorted() { tags.append(["k", String(kind)]) }
        guard let signed = await signEventAsync(kind: 5, content: "", tags: tags) else { return 0 }
        postEvent(signed)
        let ids = Set(targets.map(\.id))
        let hash = sha256.lowercased()
        events.removeAll { ids.contains($0.id) }
        noteMedia.removeAll { $0.pubkey == activeHexPubkey && $0.url.absoluteString.lowercased().contains(hash) }
        eventUpdateSubject.send()
        NotificationCenter.default.post(name: .havenOwnEventsDeleted, object: ids)
        return targets.count
    }
}
