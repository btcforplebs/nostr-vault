import Foundation
import Combine

// MARK: - Models

struct DMMessage: Identifiable, Codable {
    let id: String
    let senderPubkey: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    var isNIP04: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, senderPubkey, content, timestamp, isFromMe, isNIP04
    }

    init(id: String, senderPubkey: String, content: String, timestamp: Date, isFromMe: Bool, isNIP04: Bool = false) {
        self.id = id
        self.senderPubkey = senderPubkey
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.isNIP04 = isNIP04
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        senderPubkey = try container.decode(String.self, forKey: .senderPubkey)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFromMe = try container.decode(Bool.self, forKey: .isFromMe)
        isNIP04 = try container.decodeIfPresent(Bool.self, forKey: .isNIP04) ?? false
    }
}
