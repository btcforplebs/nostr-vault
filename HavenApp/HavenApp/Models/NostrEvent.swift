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
        case 10063: return "Server List"
        case 13194: return "Wallet Info"
        case 22242: return "Client Auth"
        case 30023: return "Long-form Post"
        case 30024: return "Draft Long-form"
        case 31234: return "Draft"
        case 31922: return "Date-based Event"
        case 31923: return "Time-based Event"
        case 31924: return "Calendar"
        case 31925: return "Calendar Event"
        case 31989: return "Handler Rec"
        case 31990: return "Handler Info"
        case 9: return "Group Chat"
        case 11: return "Thread Root"
        case 12: return "Thread Reply"
        case 9000: return "Group Add User"
        case 9001: return "Group Remove User"
        case 9002: return "Group Edit Metadata"
        case 9005: return "Group Delete Event"
        case 9007: return "Group Create"
        case 9008: return "Group Delete"
        case 9009: return "Group Invite"
        case 9021: return "Group Join Request"
        case 9022: return "Group Leave Request"
        case 39000: return "Group Metadata"
        case 39001: return "Group Admin List"
        case 39002: return "Group Member List"
        case 39003: return "Group Roles"
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

    /// A kind 6 repost always carries an `e` tag pointing at what it repeats, and a
    /// quote carries one marked "mention" (NIP-10) — neither is a reply. `parentEventId`
    /// deliberately still resolves both, because thread building needs the edge; only
    /// the reply *classification* excludes them. This matches `FeedNote.isReply` and
    /// Android's `FeedServiceTypes.kt`, which have always drawn the line here.
    var isReply: Bool {
        guard kind != 6 else { return false }
        return tags.contains { tag in
            guard tag.count >= 2, tag[0] == "e" else { return false }
            return tag.count < 4 || tag[3] != "mention"
        }
    }

    // MARK: - URL Extraction

    private static let mediaRegex: NSRegularExpression? = SupportedMediaFormats.mediaExtensionRegex

    private static let blossomRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://\S+/[a-f0-9]{64}(?=\s|$)"#, options: .caseInsensitive)
    }()

    private static let httpURLRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)
    }()

    var mediaURLs: [URL] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var urls: [URL] = []

        if let regex = Self.mediaRegex {
            urls += regex.matches(in: content, range: range)
                .compactMap { URL(string: ns.substring(with: $0.range)) }
        }
        if let regex = Self.blossomRegex {
            urls += regex.matches(in: content, range: range)
                .compactMap { URL(string: ns.substring(with: $0.range)) }
        }

        // NIP-92 imeta tags
        let imetaURLs: [URL] = tags.compactMap { tag in
            guard tag.first == "imeta", tag.count >= 2 else { return nil }
            for field in tag.dropFirst() {
                if field.hasPrefix("url ") {
                    let urlStr = String(field.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    return URL(string: urlStr)
                }
            }
            return nil
        }

        var seen = Set<String>()
        return (urls + imetaURLs).filter { seen.insert($0.absoluteString).inserted }
    }

    /// Ids of the events this note quotes (`nostr:note1…`, `nevent1…`, `naddr1…`),
    /// in content order. Same rule as `FeedNote.quotedEventIds` — one definition,
    /// so the relay tab and the timeline agree about what a note quotes.
    var quotedEventIds: [String] {
        QuoteReference.resolvedIdentifiers(in: content)
    }

    var linkURLs: [URL] {
        guard let regex = Self.httpURLRegex else { return [] }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        let mediaSet = Set(mediaURLs.map { $0.absoluteString })

        var seen = Set<String>()
        return regex.matches(in: content, range: range)
            .compactMap { URL(string: ns.substring(with: $0.range)) }
            .filter { !mediaSet.contains($0.absoluteString) }
            .filter { seen.insert($0.absoluteString).inserted }
    }
}

extension NostrEvent {
    /// This event as the feed's note model, so relay-tab rows can reuse the
    /// timeline's cards (`QuotedNoteView`, `NoteDetailView`) instead of growing
    /// a second set that renders the same thing differently.
    var asFeedNote: FeedNote {
        FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: createdAtDate,
            tags: tags,
            kind: kind
        )
    }
}
