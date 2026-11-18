import Foundation

/// "Sending…" until a relay of theirs takes a message, then sent; "Not sent"
/// with Try again and Remove when none does. Web: `net/dms.js` sendMessage.
/// The rule itself is DMDelivery; this applies it to the thread.
extension DMService {
    struct PendingDelivery {
        var tally: DMDelivery
        let conversation: String
        /// Runs once, when the first relay of theirs takes it.
        let onDelivered: () -> Void
    }

    /// Starts waiting on `relayCount` relays for message `messageId` in
    /// `conversation`. Returns the callback each relay's answer goes to.
    func beginDelivery(messageId: String, conversation: String, relayCount: Int,
                       onDelivered: @escaping () -> Void) -> (Bool) -> Void {
        let tally = DMDelivery(relayCount: relayCount)
        if let outcome = tally.outcome {
            // No relays at all: not sent, nothing to wait for.
            pendingDeliveries[messageId] = PendingDelivery(tally: tally, conversation: conversation, onDelivered: onDelivered)
            settle(messageId, outcome)
            return { _ in }
        }
        pendingDeliveries[messageId] = PendingDelivery(tally: tally, conversation: conversation, onDelivered: onDelivered)
        DispatchQueue.main.asyncAfter(deadline: .now() + DMDelivery.deadline) { [weak self] in
            Task { @MainActor in self?.recordDelivery(messageId, accepted: nil) }
        }
        return { [weak self] accepted in
            Task { @MainActor in self?.recordDelivery(messageId, accepted: accepted) }
        }
    }

    /// One relay's answer (`accepted`), or the deadline passing (nil).
    func recordDelivery(_ messageId: String, accepted: Bool?) {
        guard var pending = pendingDeliveries[messageId] else { return }
        let outcome = accepted.map { pending.tally.record(accepted: $0) } ?? pending.tally.expire()
        pendingDeliveries[messageId] = pending
        if let outcome { settle(messageId, outcome) }
    }

    private func settle(_ messageId: String, _ outcome: DMDelivery.Outcome) {
        guard let pending = pendingDeliveries.removeValue(forKey: messageId) else { return }
        switch outcome {
        case .delivered:
            setSendState(messageId, in: pending.conversation, state: nil, failure: nil)
            resends.removeValue(forKey: messageId)
            pending.onDelivered()
        case .failed(let why):
            setSendState(messageId, in: pending.conversation, state: .failed, failure: why)
        }
    }

    func setSendState(_ messageId: String, in conversation: String, state: DMSendState?, failure: String?) {
        guard let c = conversations.firstIndex(where: { $0.id == conversation }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageId }) else { return }
        conversations[c].messages[m].sendState = state
        conversations[c].messages[m].sendFailure = failure
        dmUpdateSubject.send()
        saveConversations()
    }

    /// Whether Try again can send `message` once more. A photo message is
    /// its locked link: after a relaunch its file tags are gone, so only
    /// Remove is offered (the photo can be sent again from the composer).
    func canResend(_ message: DMMessage) -> Bool {
        guard message.isFailed else { return false }
        return resends[message.id] != nil || !message.content.contains(DMFile.marker)
    }

    /// Try again: signs and sends the same message afresh as a new bubble,
    /// and drops the failed one once the new one is on its way. If signing
    /// fails, the failed bubble stays and says why.
    func resendFailed(_ messageId: String, in conversation: String) async {
        guard let c = conversations.firstIndex(where: { $0.id == conversation }),
              let message = conversations[c].messages.first(where: { $0.id == messageId }),
              canResend(message) else { return }
        let send = resends[messageId] ?? { [weak self] in
            try await self?.sendDM(content: message.content, to: conversation, useNIP04: message.isNIP04)
        }
        do {
            try await send()
            removeFailed(messageId, in: conversation)
        } catch {
            setSendState(messageId, in: conversation, state: .failed, failure: "Not sent: \(error.localizedDescription)")
        }
    }

    /// Remove: takes a not-sent message out of the thread.
    func removeFailed(_ messageId: String, in conversation: String) {
        resends.removeValue(forKey: messageId)
        guard let c = conversations.firstIndex(where: { $0.id == conversation }) else { return }
        let before = conversations[c].messages.count
        conversations[c].messages.removeAll { $0.id == messageId && $0.isFailed }
        guard conversations[c].messages.count != before else { return }
        dmUpdateSubject.send()
        saveConversations()
    }
}
