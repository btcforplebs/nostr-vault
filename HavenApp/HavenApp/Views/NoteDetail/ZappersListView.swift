import SwiftUI

// MARK: - ZappersListView

struct ZappersListView: View {
    let zaps: [NoteDetailView.ZapDetail]
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedProfilePubkey: String?

    var body: some View {
        NavigationView {
            List(zaps, id: \.id) { zap in
                let profile = nostrService.profiles[zap.zapperPubkey]
                Button {
                    selectedProfilePubkey = zap.zapperPubkey
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: zap.zapperPubkey, size: 40)
                            .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.1), radius: 3)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile?.bestName ?? "npub…" + String(zap.zapperPubkey.suffix(6)))
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(zap.amountSats) sats")
                                    .font(.appSystem(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                            }
                            if !zap.comment.isEmpty {
                                Text(zap.comment)
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    // The whole row, not just the avatar and text: a .plain
                    // button on the Mac only takes clicks where it draws.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .navigationTitle("Zaps")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { selectedProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { selectedProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { selectedProfilePubkey = nil })
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, minHeight: 400)
        #endif
    }
}
