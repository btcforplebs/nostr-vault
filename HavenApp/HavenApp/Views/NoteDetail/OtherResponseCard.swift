import SwiftUI

/// One "below the fold" response: who, what kind, and the text. Quotes link
/// through to the quoting note.
struct OtherResponseCard: View {
    let note: FeedNote
    let profile: FeedProfile?

    private var label: (String, String) {
        switch note.kind {
        case 1: return ("Quoted", "quote.bubble")
        case 9802: return ("Highlighted", "highlighter")
        case 1244: return ("Voice reply", "waveform")
        default: return ("Responded", "arrowshape.turn.up.left")
        }
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 22)
                Text(profile?.bestName ?? String(note.pubkey.prefix(8)))
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)
                Label(label.0, systemImage: label.1)
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            let text = NostrContentFormatter.format(note.content, mediaURLs: note.mediaURLs)
            if !text.characters.isEmpty {
                Text(text)
                    .font(.appSystem(size: 14))
                    .lineLimit(note.kind == 9802 ? 6 : 4)
                    .padding(.leading, note.kind == 9802 ? 8 : 0)
                    .overlay(alignment: .leading) {
                        if note.kind == 9802 {
                            Rectangle().fill(Color.havenPurple.opacity(0.6)).frame(width: 3)
                        }
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))

        if note.kind == 1 {
            NoteNavigationLink(note: note) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}
