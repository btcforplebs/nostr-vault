import Foundation

/// Muted words in DMs: a conversation where the other person used one is
/// left out of the inbox and requests, its unread count and its alerts
/// (`MuteList.hidesConversation`). It stays stored, and the inbox's last row
/// says how many are hidden and can show them. Android: DMMutedWords.kt;
/// web: dms.js.
extension DMService {
    /// Conversations a muted word hides, already left out of the inbox.
    var mutedWordConversations: [DMConversation] {
        let list = MuteListStore.shared.active
        guard !list.words.isEmpty else { return [] }
        return BlockedPeople.visibleConversations(conversations, blocked: ConfigService.shared.activeAccountBlockedHexPubkeys) { $0.id }
            .filter { DMMutedWordsMemo.shared.hides($0, list: list) }
    }

    /// `conversations` without the ones a muted word hides, unless the
    /// person chose to show them.
    func withoutMutedWords(_ conversations: [DMConversation]) -> [DMConversation] {
        guard !showsMutedWordConversations else { return conversations }
        let list = MuteListStore.shared.active
        guard !list.words.isEmpty else { return conversations }
        return conversations.filter { !DMMutedWordsMemo.shared.hides($0, list: list) }
    }

    /// Whether a muted word hides the conversation with `counterparty`.
    /// Its messages never alert, even while hidden ones are shown.
    func isHiddenByMutedWords(_ counterparty: String) -> Bool {
        let list = MuteListStore.shared.active
        guard !list.words.isEmpty,
              let conversation = conversations.first(where: { $0.id == counterparty }) else { return false }
        return DMMutedWordsMemo.shared.hides(conversation, list: list)
    }
}

/// The inbox is worked out on every redraw: a conversation is scanned again
/// only when its messages or the muted words change.
@MainActor
final class DMMutedWordsMemo {
    static let shared = DMMutedWordsMemo()
    private var memo: [String: (key: String, hides: Bool)] = [:]
    private var words: [String] = []

    func hides(_ conversation: DMConversation, list: MuteList) -> Bool {
        if list.words != words {
            words = list.words
            memo.removeAll()
        }
        let key = "\(conversation.messages.count):\(conversation.messages.last?.id ?? ""):\(conversation.messages.first?.id ?? "")"
        if let hit = memo[conversation.id], hit.key == key { return hit.hides }
        let hides = list.hidesConversation(conversation.messages)
        memo[conversation.id] = (key, hides)
        return hides
    }
}
