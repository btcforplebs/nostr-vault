import SwiftUI

/// One tile in the Recipes grid. Image-forward: the hero image is present on
/// most zap.cooking recipes and is the thing people actually browse by.
struct RecipeCardView: View {
    let note: FeedNote
    let profile: FeedProfile?

    private var metadata: LongFormMetadata { note.longFormMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let imageURL = metadata.imageURL {
                    RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 600, height: 600))
                } else {
                    ZStack {
                        Rectangle().fill(Color.havenPurplePale)
                        Image(systemName: "fork.knife")
                            .font(.appSystem(size: 28))
                            .foregroundColor(.havenPurple.opacity(0.7))
                    }
                }
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(note.longFormDisplayTitle)
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .openInWebContextMenu(note.webLink)
    }
}

/// Horizontal category chips built from the `zapcooking-<category>` tags
/// present in the loaded results — not a hardcoded list, so it stays honest
/// about what is actually there.
struct RecipeCategoryBar: View {
    let categories: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: selected == nil) { selected = nil }
                ForEach(categories, id: \.self) { category in
                    chip(title: category.capitalized, isOn: selected == category) {
                        selected = (selected == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? Color.havenPurple : Color.havenPurplePale)
                .foregroundColor(isOn ? .white : .havenPurple)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
