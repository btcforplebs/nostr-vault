import SwiftUI

/// A note whose star just landed on the globe: who wrote it and its first
/// line, small and quiet beside the face. Tapping it opens the note.
struct GlobeNotePreview: View {
    let avatar: AnyView
    let name: String
    let text: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                avatar
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(text)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name): \(text)"))
        .accessibilityHint(Text("Opens the note"))
        .accessibilityIdentifier("globeNotePreview")
    }
}
