import Foundation

struct NostrEvent: Codable, Identifiable {
    let id: String
    let pubkey: String
    let created_at: Int64
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String
    
    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(created_at))
    }
    
    var kindDescription: String {
        switch kind {
        case 0: return "Metadata"
        case 1: return "Text Note"
        case 2: return "Recommend Relay"
        case 3: return "Contacts"
        case 4: return "Encrypted DM"
        case 5: return "Event Deletion"
        case 6: return "Repost"
        case 7: return "Reaction"
        case 40: return "Channel Creation"
        case 41: return "Channel Meta"
        case 42: return "Channel Message"
        case 43: return "Channel Hide"
        case 44: return "Channel Mute"
        case 1063: return "File Metadata"
        case 1984: return "Reporting"
        case 9734: return "Zap Request"
        case 9735: return "Zap"
        case 10000: return "Mute List"
        case 10001: return "Pin List"
        case 10002: return "Relay List"
        case 13194: return "Wallet Info"
        case 22242: return "Client Auth"
        case 30023: return "Long-form Post"
        case 30024: return "Draft Long-form"
        case 31922: return "Date-based Event"
        case 31923: return "Time-based Event"
        case 31924: return "Calendar"
        case 31925: return "Calendar Event"
        case 31989: return "Handler Rec"
        case 31990: return "Handler Info"
        default: return "Kind \(kind)"
        }
    }
    
    var parentEventId: String? {
        // Look for 'e' tags. NIP-10 says the last 'e' tag is usually the one being replied to
        // unless there are explicit markers like "reply" or "root".
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        if eTags.isEmpty { return nil }
        
        // Check for explicit "reply" marker
        if let replyTag = eTags.first(where: { $0.count >= 4 && $0[3] == "reply" }) {
            return replyTag[1]
        }
        
        // If no "reply" marker, but there is a "root" marker, and more than one 'e' tag,
        // the one without "root" is likely the reply. 
        // For simplicity, we'll take the LAST 'e' tag as per common legacy behavior.
        return eTags.last?[1]
    }

    var isReply: Bool {
        return parentEventId != nil
    }
}
