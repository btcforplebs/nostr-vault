import SwiftUI

/// The feature descriptions that used to fill the first screen.
struct WhatsInsideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let features: [(icon: String, title: String, line: String)] = [
        ("externaldrive.connected.to.line.below", "Your Vault", "Your own relay, on this device. Notes are kept here and sent to the network, so you always have a copy."),
        ("doc.text.image", "Full Nostr Client", "Browse your feed, post notes, reply, repost, and discover content from the network."),
        ("lock.shield", "Private Messaging", "NIP-17 encrypted DMs that stay on your device. No third-party server reads your conversations."),
        ("photo.stack", "Your Media", "Keep images and videos in your vault, and copy them to your media servers."),
        ("bolt.fill", "Lightning Zaps", "Send and receive zaps over Lightning by connecting your own wallet with Nostr Wallet Connect.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("What's inside")
                    .font(.appSystem(size: 20, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(WizardColors.accentPrimary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(features, id: \.title) { feature in
                        featureRow(feature.icon, feature.title, feature.line)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(WizardColors.bgPrimary.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 480, height: 560)
        #endif
    }

    private func featureRow(_ icon: String, _ title: String, _ line: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.appSystem(size: 20))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                Text(line)
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(WizardColors.bgCard)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(WizardColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
