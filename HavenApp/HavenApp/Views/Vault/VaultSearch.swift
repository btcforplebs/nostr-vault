import SwiftUI

struct ProfileResultRow: View {
    let profile: FeedProfile
    @State private var isHovered = false

    /// The name, or for someone with no profile yet (a pasted npub) the
    /// whole npub, so its start and end can be checked against what was
    /// pasted. `bestName`'s "npub…" + six hex characters cannot be.
    private var title: String {
        let named = [profile.displayName, profile.name].contains { !($0 ?? "").isEmpty }
        if !named, let npub = ProfileFormat.npub(profile.pubkey) { return npub }
        return profile.bestName
    }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(url: profile.pictureURL, pubkey: profile.pubkey, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let nip05 = profile.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(.appSystem(size: 13, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }
}
