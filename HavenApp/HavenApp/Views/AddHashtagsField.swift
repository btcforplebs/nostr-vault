import SwiftUI

/// Follow many hashtags at once from the Hashtags feed: type or paste
/// "#bitcoin #nostr art", tap Add, and they all go into one published list.
/// Pieces that can't be a hashtag stay in the field, with a note saying so.
/// Android: AddHashtagsField.
struct AddHashtagsField: View {
    /// Follows the parsed tags; false when the list wasn't saved.
    let follow: ([String]) async -> Bool
    let alreadyFollowed: [String]

    @State private var text = ""
    @State private var note: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Add hashtags: #art #music…", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused)
                    .onSubmit(add)
                    .onChange(of: text) { _, _ in note = nil }
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func add() {
        let parsed = InterestList.parseHashtags(text)
        let fresh = parsed.hashtags.filter { !alreadyFollowed.contains($0) }
        text = parsed.rejected.joined(separator: " ")
        let rejectedNote: String? = switch parsed.rejected.count {
        case 0: nil
        case 1: "\u{201C}\(parsed.rejected[0])\u{201D} isn't a hashtag: use letters, numbers or _."
        default: "These aren't hashtags: use letters, numbers or _."
        }
        note = rejectedNote
        if parsed.rejected.isEmpty { focused = false }
        guard !fresh.isEmpty else { return }
        saving = true
        Task {
            _ = await follow(fresh)
            saving = false
        }
    }
}
