import SwiftUI

#if os(macOS)

/// An opened note in its own column beside the list: the web app's "Thread"
/// column. The Mac used to cover the whole window with a sheet for this, so
/// the list you came from was gone while you read. Esc or ✕ closes it.
struct MacThreadPane: View {
    @ObservedObject var selection: NoteDetailSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Thread")
                    .font(.appSystem(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                Button { selection.clear() } label: {
                    Image(systemName: "xmark")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close thread (Esc)")
                .accessibilityLabel("Close thread")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)

            Group {
                if let note = selection.note {
                    NavigationStack {
                        NoteDetailView(note: note)
                    }
                    .id(note.id)
                } else if let noteId = selection.noteId {
                    NavigationStack {
                        NoteDetailViewWrapper(noteId: noteId, onDismiss: { selection.clear() }, pushed: true)
                    }
                    .id(noteId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformWindowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.28), lineWidth: 1)
        )
    }
}

#endif
