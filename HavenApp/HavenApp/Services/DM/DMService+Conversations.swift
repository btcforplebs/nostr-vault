import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

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
        // Don't refetch if we just did it recently (within 5 minutes)
        guard DMSignerPolicy.fetchDue(lastFetch: lastExternalFetchTimestamp, now: now) else { return }
        fetchFromExternalRelays()
    }

    /// Background App Refresh: the same 5-minute fetch, but with a bunker
    /// nothing is put in front of the signer while the app is closed: no read
    /// AUTH, no decrypts. The wraps it finds wait for the next foreground.
    func syncInBackground() {
        syncOnForeground()
    }

    /// Every return to the app (and a DM notification or widget tap). With a
    /// bunker this used to ask for the vault login each time: the outside
    /// fetch skipped the 5-minute guard, and every wrap the signer had
    /// refused was asked about again. Now the fetch keeps its guard and only
    /// wraps that got no answer go back to the signer; refused ones wait for
    /// Retry (signer audit item 5).
    func refresh() {
        // Anything the signer did not answer gets another try now.
        retryWaitingForSigner(userAsked: false)
        // Reconnect to the local chat relay
        reconnectInbox()
        // Also fetch from external relays, at most every 5 minutes.
        syncOnForeground()
    }

    /// Whether the app is in front. Only iOS can run DM work with the app
    /// closed (Background App Refresh); the Mac and a test host count as in front.
    var appIsInFront: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// May the DM code ask the active account's signer now (decrypts, read
    /// AUTH)? A bunker only with the app in front.
    var mayAskActiveSigner: Bool {
        DMSignerPolicy.mayAskSigner(needsPerson: ConfigService.shared.config.activeSigningMode() == "nip46",
                                    appActive: appIsInFront)
    }

    /// May the /chat AUTH (always signed as the owner) ask now?
    var mayAskOwnerSigner: Bool {
        DMSignerPolicy.mayAskSigner(needsPerson: ConfigService.shared.config.ownerSignsWithBunker,
                                    appActive: appIsInFront)
    }

    /// The app came to the front: send the signer what waited for it there.
    /// Wraps held in the background (never asked) go now; refused ones still
    /// wait for Retry; the /chat AUTH kept from the background is signed.
    func resumeSignerWorkInFront() {
        retryWaitingForSigner(userAsked: false)
        retryPendingAuth()
        if nip04HeldForSigner {
            nip04HeldForSigner = false
            restartNIP04IfNeeded()
        }
    }

    func sortConversations() {
        conversations.sort { ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast) }
    }
}
