import Foundation
import Combine

// MARK: - Models

/// Where a message you sent stands. Nil once a relay of theirs took it (or
/// for anything you received): the bubble shows as sent.
enum DMSendState: String, Codable {
    /// Signed and on its way: no relay of theirs has taken it yet.
    case sending
    /// None of their relays took it (refused, timed out, or none found).
    case failed
}

struct DMMessage: Identifiable, Codable {
    let id: String
    let senderPubkey: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    var isNIP04: Bool = false
    /// Sending / not sent, for your own messages (web dms.js `pending` / `failed`).
    var sendState: DMSendState? = nil
    /// Why it was not sent, shown under a failed bubble.
    var sendFailure: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, senderPubkey, content, timestamp, isFromMe, isNIP04, sendState, sendFailure
    }

    /// Said under a message that was still sending when the app last closed:
    /// nothing will finish it now, so it reads as not sent.
    static let interruptedSend = "Not sent: the app closed before a relay took it."

    init(id: String, senderPubkey: String, content: String, timestamp: Date, isFromMe: Bool, isNIP04: Bool = false,
         sendState: DMSendState? = nil, sendFailure: String? = nil) {
        self.id = id
        self.senderPubkey = senderPubkey
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.isNIP04 = isNIP04
        self.sendState = sendState
        self.sendFailure = sendFailure
    }

    var isSending: Bool { sendState == .sending }
    var isFailed: Bool { sendState == .failed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        senderPubkey = try container.decode(String.self, forKey: .senderPubkey)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFromMe = try container.decode(Bool.self, forKey: .isFromMe)
        isNIP04 = try container.decodeIfPresent(Bool.self, forKey: .isNIP04) ?? false
        sendState = try container.decodeIfPresent(DMSendState.self, forKey: .sendState)
        sendFailure = try container.decodeIfPresent(String.self, forKey: .sendFailure)
        // Read back from disk, a send still under way belongs to a run that
        // ended: no relay answer will come for it any more.
        if sendState == .sending {
            sendState = .failed
            sendFailure = Self.interruptedSend
        }
    }
}
