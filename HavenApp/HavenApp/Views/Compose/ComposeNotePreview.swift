import SwiftUI

/// The note being written, drawn by the feed's own row (`FeedNoteRow`), so
/// link previews, live stream cards, quoted notes, hashtags, mentions and
/// photos look exactly as they will once posted. Read-only: the row's
/// buttons do nothing here.
struct ComposeNotePreview: View {
    let note: FeedNote?
    /// Attachments still going up; they join the preview when they land.
    let uploadingCount: Int

    @EnvironmentObject var nostrService: NostrService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                if let note {
                    FeedNoteRow(
                        note: note,
                        profile: nostrService.profiles[note.pubkey],
                        rowData: FeedNoteRowData.resolve(for: note, feedService: FeedService.shared, nostrService: nostrService),
                        showParent: false
                    )
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Preview of your note")
                } else {
                    Text("Your note shows here as it will look in the feed.")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if uploadingCount > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(uploadingCount == 1
                             ? "1 attachment is still uploading. It appears here when it lands."
                             : "\(uploadingCount) attachments are still uploading. They appear here when they land.")
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.platformSecondaryGroupedBackground)
        // Inside the composer's sheet: a link must not push behind it.
        .environment(\.pushNoteID, nil)
    }
}
