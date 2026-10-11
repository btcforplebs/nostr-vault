import Foundation
import Combine

struct DMConversation: Identifiable, Codable {
    let id: String  // counterparty hex pubkey
    var messages: [DMMessage]
    var unreadCount: Int

    var lastMessage: DMMessage? {
        messages.last
    }

    var hasNIP04Messages: Bool {
        messages.contains(where: { $0.isNIP04 })
    }

    enum CodingKeys: String, CodingKey {
        case id, messages, unreadCount
    }
}
