import SwiftUI

// MARK: - Quoted Note Skeleton

/// Placeholder for a quote whose note hasn't arrived. Mirrors `QuotedNoteView`'s
/// header and a two-line body (redacted) so the card holds roughly its final
/// height instead of growing out of nothing.
struct QuotedNoteSkeleton: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.platformSecondaryGroupedBackground)
                    .frame(width: 18, height: 18)
                Text("Loading name")
                    .font(.appSystem(size: 12, weight: .semibold))
                Spacer()
                Text("00m")
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
            }
            Text("Loading the quoted note so its text can be shown here")
                .font(.appSystem(size: 13, weight: .regular))
                .lineLimit(2)
        }
        .redacted(reason: .placeholder)
        .foregroundColor(Color.platformSecondaryGroupedBackground)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderStrong, lineWidth: 1)
        )
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(Motion.shimmer, value: shimmer)
        .onAppear { if Motion.shimmer != nil { shimmer = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading quoted note")
    }
}
