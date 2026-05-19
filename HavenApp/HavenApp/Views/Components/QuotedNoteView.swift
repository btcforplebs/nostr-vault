import SwiftUI

struct QuotedNoteView: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let profile = nostrService.profiles[note.pubkey]
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 18)
                
                Text(profile?.bestName ?? "Someone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                
                Spacer()
                
                Text(relativeTime(note.createdAt))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            
            Text(NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs, hideQuotes: true))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.havenPurple.opacity(0.15), lineWidth: 1)
        )
    }
    
    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}
