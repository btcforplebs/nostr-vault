import SwiftUI

/// The Vault media viewer's swipe up: every note on the vault that uses the
/// file (`MediaNoteMatch`), newest first. A row closes the viewer and opens
/// the note.
struct MediaNotesSheet: View {
    let notes: [NostrEvent]
    let onOpen: (String) -> Void
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.appSystem(size: 28))
                            .foregroundColor(.secondary)
                        Text("No note on your vault uses this file")
                            .font(.appSubheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(notes, id: \.id) { note in
                        Button { onOpen(note.id) } label: { row(note) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(notes.count == 1 ? "1 note" : "\(notes.count) notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { nostrService.fetchMissingProfiles(for: Array(Set(notes.map(\.pubkey)))) }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func row(_ note: NostrEvent) -> some View {
        let profile = nostrService.profiles[note.pubkey]
        return HStack(alignment: .top, spacing: 10) {
            AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile?.bestName ?? String(note.pubkey.prefix(10)))
                        .font(.appSystem(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(note.createdAtDate, style: .relative)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(Self.preview(note.content))
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The text with its links folded away, so two lines say something.
    static func preview(_ content: String) -> String {
        let words = content.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("http") }
        let text = words.joined(separator: " ")
        return text.isEmpty ? "(media only)" : text
    }
}

/// The grabber at the foot of a media viewer: swipe up, or tap it, for the
/// note(s). On the Mac, where there is no swipe, it is the way in (or ↑).
struct MediaViewerNoteGrabber: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.appSystem(size: 12, weight: .bold))
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Swipe up on the media, or tap here")
    }
}
