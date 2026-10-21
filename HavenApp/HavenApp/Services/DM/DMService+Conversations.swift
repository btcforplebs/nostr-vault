import Foundation
import Combine

extension DMService {
    func isOwnSentWrap(_ eventId: String) -> Bool {
        sentSelfWrapIds.contains(eventId)
    }

    /// The conversation holding the message decrypted from event `eventId`
    /// (a gift wrap's id, or a NIP-04 event's), and that message.
    func message(withEventId eventId: String) -> (conversationId: String, message: DMMessage)? {
        for conversation in conversations {
            if let message = conversation.messages.last(where: { $0.id == eventId }) {
                return (conversation.id, message)
            }
        }
        return nil
    }

    /// Waits for the inbox to decrypt an event the relay has just reported.
    /// The relay's notification marker and this service's own subscription see
    /// the same event at nearly the same moment, so the message is usually
    /// here already or within a beat. Nil when it does not arrive in time —
    /// another account's inbox, a signer that is offline, or a connection that
    /// is asleep in the background.
    func waitForMessage(withEventId eventId: String, timeout: TimeInterval) async -> (conversationId: String, message: DMMessage)? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = message(withEventId: eventId) { return found }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func markRead(conversationWith pubkey: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == pubkey }) else { return }
        conversations[idx].unreadCount = 0
        saveConversations()
    }

    func markAllAsRead() {
        for idx in conversations.indices {
            conversations[idx].unreadCount = 0
        }
        saveConversations()
    }

    /// Called on app foreground. Fetches external DMs if enough time has elapsed.
    func syncOnForeground() {
        let now = Int64(Date().timeIntervalSince1970)
        let lastFetch = lastExternalFetchTimestamp
        // Don't refetch if we just did it recently (within 5 minutes)
        guard now - lastFetch > 300 else { return }
        fetchFromExternalRelays()
    }

    func refresh() {
        // Anything the signer could not open gets another try now.
        retryWaitingForSigner()
        // Reconnect to the local chat relay
        reconnectInbox()
        // Also fetch from external relays
        fetchFromExternalRelays()
    }

    func sortConversations() {
        conversations.sort { ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast) }
    }
}
