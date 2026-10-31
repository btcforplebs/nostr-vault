import SwiftUI

// MARK: - Step 17: Your starter relay list

/// Setup's relay list step, on the create-account path only (Logen
/// 2026-10-31, 1C). A brand-new key has no relay list (kind 10002), and
/// without one other apps can't find its posts. The step shows the servers
/// posts go to, one Continue, and a small Change link that opens Relays;
/// the list follows what is saved there. Continue publishes only what is
/// shown, once setup has stored the key. Android shows the same step.
struct StarterRelayListStep: View {
    /// The servers to show and publish (wss, reachable by others).
    let starter: [String]
    /// The relays to publish (none when the list is empty).
    let onContinue: ([String]) -> Void

    @EnvironmentObject var configService: ConfigService
    @State private var changing = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 12)
            Text("Your posts will be shared through these servers")
                .font(.appSystem(size: 22, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            WizardGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    if starter.isEmpty {
                        Text("No servers. Tap Change to add one.")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    ForEach(starter, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(WizardColors.accentPrimary)
                                .accessibilityHidden(true)
                            Text(RelayMatrix.label(url))
                                .font(.appSystem(size: 15))
                                .foregroundColor(WizardColors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: "Continue", action: { onContinue(starter) })
                WizardSkipLink(title: "Change") { changing = true }
            }
            .padding(.top, 8)
            Spacer(minLength: 8)
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.fadeIn, value: appeared)
        .onAppear { appeared = true }
        .sheet(isPresented: $changing) {
            NavigationStack {
                RelayMatrixView(inSheet: true).settingsPage("Relays")
            }
            .environmentObject(configService)
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 640)
            #endif
        }
    }
}
