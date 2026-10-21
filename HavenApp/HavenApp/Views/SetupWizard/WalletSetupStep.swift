import SwiftUI

// MARK: - Step 6: Wallet Setup

struct WalletSetupStep: View {
    @Binding var nwcURI: String
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var lightningExpanded = false
    @State private var nwcStatus: ConnectionStatus = .idle

    enum ConnectionStatus {
        case idle, testing, connected, failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.wallet.title"))
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.wallet.subtitle"))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Lightning (NWC) section
            VStack(spacing: 0) {
                Button(action: { withAnimation(WizardAnimations.springEnter) { lightningExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 18))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.wallet.lightning.title"))
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(WizardColors.textPrimary)
                        Spacer()
                        Image(systemName: lightningExpanded ? "chevron.up" : "chevron.down")
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)

                if lightningExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().background(WizardColors.borderSubtle)

                        WizardInputField(label: String(localized: "setup.wallet.lightning.label"), text: $nwcURI, placeholder: "nostr+walletconnect://...")

                        Text(String(localized: "setup.wallet.lightning.hint"))
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)

                        // Connection status
                        if nwcStatus == .testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(WizardColors.accentPrimary)
                                Text(String(localized: "setup.wallet.lightning.connecting"))
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(WizardColors.textSecondary)
                            }
                        } else if nwcStatus == .connected {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.success).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.connected"))
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(WizardColors.success)
                            }
                        } else if nwcStatus == .failed {
                            HStack(spacing: 6) {
                                Circle().fill(WizardColors.error).frame(width: 8, height: 8)
                                Text(String(localized: "setup.wallet.lightning.failed"))
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(WizardColors.error)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.wallet.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }
}
