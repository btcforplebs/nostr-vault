import SwiftUI

/// On your own globe with no desktop Vault paired: the faint outer rings'
/// invite. "Pair a desktop Vault" opens Add a device; "Not now" puts it away
/// until Settings › Feeds › Discovery Reach brings it back. Never says
/// "Haven" (Logen 2026-11-22). Android twin:
/// `ui/components/trustweb/HavenInviteCard.kt`.
struct HavenInviteCard: View {
    let onNotNow: () -> Void
    @EnvironmentObject var configService: ConfigService
    @State private var pairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("There's more out here")
                .font(.appSystem(size: 15, weight: .semibold))
            Text("\(TrustMapOuter.pairLine). Your desktop Vault ranks people three or more hops out and sends the scores to this device.")
                .font(.appSystem(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Pair a desktop Vault") { pairing = true }
                    .buttonStyle(.borderedProminent)
                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
        .sheet(isPresented: $pairing) { PairDeviceView().environmentObject(configService) }
    }
}
