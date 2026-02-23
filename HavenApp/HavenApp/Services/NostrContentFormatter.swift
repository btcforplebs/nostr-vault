import SwiftUI
import Foundation

public struct NostrContentFormatter {
    @MainActor
    public static func format(_ content: String, mediaURLs: [URL] = []) -> AttributedString {
        var text = content
        
        // Strip bare image/video URLs from text (they'll show as thumbnails)
        for url in mediaURLs {
            text = text.replacingOccurrences(of: url.absoluteString, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Resolve nostr:npub and nostr:nprofile
        let npubRegex = try! NSRegularExpression(pattern: "nostr:(npub1[a-z0-9]+)")
        let nprofileRegex = try! NSRegularExpression(pattern: "nostr:(nprofile1[a-z0-9]+)")
        
        text = replaceWithLinks(in: text, regex: npubRegex, template: "nostr:$1")
        text = replaceWithLinks(in: text, regex: nprofileRegex, template: "nostr:$1")
        
        // Resolve nostr:note and nostr:nevent
        let noteRegex = try! NSRegularExpression(pattern: "nostr:(note1[a-z0-9]+)")
        let neventRegex = try! NSRegularExpression(pattern: "nostr:(nevent1[a-z0-9]+)")
        
        text = replaceWithLinks(in: text, regex: noteRegex, template: "nostr:$1", label: "Quote")
        text = replaceWithLinks(in: text, regex: neventRegex, template: "nostr:$1", label: "Quote")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            var attrString = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            attrString.foregroundColor = .primary
            return attrString
        } catch {
            return AttributedString(text)
        }
    }
    
    @MainActor
    private static func replaceWithLinks(in text: String, regex: NSRegularExpression, template: String, label: String? = nil) -> String {
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        var result = text
        var offset = 0
        
        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            let matchedValue = nsString.substring(with: match.range(at: 1))
            
            var displayLabel: String
            if let label = label {
                displayLabel = label
            } else {
                // Try to find a name for this pubkey if it's an npub
                if matchedValue.hasPrefix("npub1") {
                    if let decoded = Bech32.decode(matchedValue) {
                        let hex = decoded.hexString
                        if let name = NostrService.shared.profiles[hex]?.bestName {
                            displayLabel = "@\(name)"
                        } else {
                            displayLabel = "@user"
                        }
                    } else {
                        displayLabel = "@user"
                    }
                } else if matchedValue.hasPrefix("nprofile1") {
                    // nprofile is more complex (TLV), but for now we'll just say @user
                    // unless we want to implement TLV decoding
                    displayLabel = "@user"
                } else {
                    displayLabel = "@user"
                }
            }
            
            let markdownLink = "[\(displayLabel)](nostr:\(matchedValue))"
            let prevLength = fullRange.length
            result = (result as NSString).replacingCharacters(in: fullRange, with: markdownLink)
            offset += markdownLink.count - prevLength
        }
        
        return result
    }
}
