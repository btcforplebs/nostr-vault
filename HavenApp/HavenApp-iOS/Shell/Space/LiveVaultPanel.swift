import SwiftUI

/// Live Vault, the web's first Your space panel: who is replying, liking,
/// zapping and following, newest on top. Lines that arrive after it was
/// drawn go on top by themselves; if you are reading further down, the row
/// you're on stays put. A row opens what it's about on the left.
struct LiveVaultPanel: View {
    @ObservedObject var model: LiveVaultModel
    @ObservedObject private var nostrService = NostrService.shared

    var body: some View {
        let rows = model.rows
        VStack(spacing: 0) {
            faces(rows: rows)
            Divider().opacity(0.6)
            list(rows)
        }
    }

    private func faces(rows: [VaultActivity]) -> some View {
        let unread = model.unreadCount
        let (faces, more) = LiveVault.faces(unread > 0 ? Array(model.lines.prefix(unread)) : rows)
        return HStack(spacing: 8) {
            HStack(spacing: -8) {
                ForEach(faces, id: \.self) { pk in
                    AvatarView(url: nostrService.profiles[pk]?.pictureURL, pubkey: pk, size: 28)
                        .overlay(Circle().stroke(Color.platformWindowBackground, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            if more > 0 {
                Text("+\(more)")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func list(_ rows: [VaultActivity]) -> some View {
        if rows.isEmpty {
            Text(nostrService.isFetching ? "Loading your vault..." : "Replies, likes, zaps and new followers land here")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { line in
                        Button { model.open(line) } label: {
                            VaultActivityRow(line: line, isUnread: model.seenAt > 0 && line.createdAt > model.seenAt, compact: true)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
                .scrollTargetLayout()
            }
            // Lines put on top keep the row in view where it is.
            .scrollPosition(id: $model.topId, anchor: .top)
        }
    }
}
