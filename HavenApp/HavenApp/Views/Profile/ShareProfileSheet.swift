import SwiftUI

/// Share profile: the profile's nostrvault.app/p/ address as a QR code to
/// scan, a Copy link button and the system share sheet. Opened from your own
/// profile's share button and from the ••• menu on anyone's profile.
/// Android's twin is ShareProfileSheet.kt.
struct ShareProfileSheet: View {
    let pubkey: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var profile: FeedProfile? { NostrService.shared.profiles[pubkey] }
    private var name: String { profile?.bestName ?? ProfileFormat.shortPubkey(pubkey) }
    private var link: URL? { ProfileFormat.npub(pubkey).flatMap { ProfileShareLink.url(npub: $0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 56)
                        Text(name)
                            .font(.appSystem(size: 18, weight: .bold))
                            .lineLimit(1)
                    }
                    if let link {
                        code(for: link)
                        Text(link.absoluteString.replacingOccurrences(of: "https://", with: ""))
                            .font(.appSystem(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                        buttons(for: link)
                    } else {
                        Text("This profile has no public key to share.")
                            .foregroundColor(.secondary)
                    }
                    Text("Scan with a phone camera or Nostr Vault to open this profile.")
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Share profile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 520)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// Dark modules on white with a quiet zone: what every camera reads,
    /// whatever the app's theme.
    @ViewBuilder
    private func code(for link: URL) -> some View {
        if let cg = MeshQRCode.cgImage(for: link.absoluteString) {
            Image(decorative: cg, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .padding(16)
                .background(Color.white)
                .cornerRadius(16)
                .accessibilityLabel("QR code for \(name)'s profile")
        }
    }

    private func buttons(for link: URL) -> some View {
        HStack(spacing: 10) {
            Button {
                ProfileFormat.copy(link.absoluteString)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { copied = false }
                }
            } label: {
                Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.havenPurple)
                    .background(Color.havenPurple.opacity(0.12))
                    .cornerRadius(10)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            ShareLink(item: link, subject: Text(name), message: Text("\(name) on Nostr")) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.white)
                    .background(Color.havenPurple)
                    .cornerRadius(10)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}
