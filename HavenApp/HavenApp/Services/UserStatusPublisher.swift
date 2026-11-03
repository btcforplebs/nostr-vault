import Foundation

/// Publishes a NIP-38 user status (kind 30315). Used by the Share Portal's
/// "Share what I'm playing"; public, and it expires on its own.
@MainActor
enum UserStatusPublisher {
    static func publish(text: String, url: String?, lasting seconds: Int, for intent: NVShareIntent,
                        now: Date = Date()) async throws {
        let expiration = Int(now.timeIntervalSince1970) + seconds
        let tags = StatusShareTags.tags(text: text, url: url, expiration: expiration)
        try await SharePortalPosting.publish(kind: StatusShareTags.kind,
                                             content: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                             tags: tags, for: intent)
    }
}
