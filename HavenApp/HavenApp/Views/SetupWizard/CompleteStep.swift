import SwiftUI

// MARK: - Step 7: Complete

struct CompleteStep: View {
    let isBrowseMode: Bool
    var isNewUser: Bool = false
    let onLaunch: () -> Void
    @State private var showContent = false
    @State private var ringScale: CGFloat = 0
    @State private var ringOpacity: Double = 1
    @State private var ring2Scale: CGFloat = 0
    @State private var ring2Opacity: Double = 1
    @State private var ring3Scale: CGFloat = 0
    @State private var ring3Opacity: Double = 1
    @State private var buttonPulse: Bool = false

    var body: some View {
        // New users get the relay/Blossom explainer too, so their screen
        // tightens up to keep Start Exploring above the fold on an SE.
        VStack(spacing: isNewUser ? 18 : 28) {
            Spacer().frame(height: isNewUser ? 8 : 40)

            // Celebration animation
            ZStack {
                // Expanding rings
                Circle()
                    .stroke(WizardColors.accentPrimary, lineWidth: 2)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(ring2Scale)
                    .opacity(ring2Opacity)
                    .frame(width: 120, height: 120)

                Circle()
                    .stroke(WizardColors.accentPrimary.opacity(0.3), lineWidth: 1)
                    .scaleEffect(ring3Scale)
                    .opacity(ring3Opacity)
                    .frame(width: 120, height: 120)

                // Checkmark seal
                Image(systemName: "checkmark.seal.fill")
                    .font(.appSystem(size: 72))
                    .foregroundStyle(WizardColors.accentGradient)
                    .scaleEffect(showContent ? 1.0 : 0)
                    .animation(WizardAnimations.springBounce.delay(0.5), value: showContent)
            }

            // Title
            Text(isNewUser ? "Welcome to Nostr!" : (isBrowseMode ? String(localized: "setup.complete.title.browse") : String(localized: "setup.complete.title.full")))
                .font(.appSystem(size: isIOSDevice ? 28 : 32, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 15)
                .animation(WizardAnimations.springEnter.delay(0.8), value: showContent)

            // Summary bullets
            VStack(alignment: .leading, spacing: 14) {
                if isNewUser {
                    completeBullet(icon: "checkmark.circle.fill", text: "Account created", color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "checkmark.circle.fill", text: "Relay is running", color: WizardColors.success, delay: 1.1)
                } else if isBrowseMode {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.browse.connected"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "info.circle.fill", text: String(localized: "setup.complete.browse.upgradeHint"), color: WizardColors.accentPrimary, delay: 1.1)
                } else {
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.relayRunning"), color: WizardColors.success, delay: 1.0)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.dmsEnabled"), color: WizardColors.success, delay: 1.1)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.blossomActive"), color: WizardColors.success, delay: 1.2)
                    completeBullet(icon: "checkmark.circle.fill", text: String(localized: "setup.complete.full.postsBroadcast"), color: WizardColors.success, delay: 1.3)
                }
            }

            if isNewUser {
                // How the on-device relay and Blossom reach everyone else.
                VStack(alignment: .leading, spacing: 12) {
                    explainerRow(icon: "antenna.radiowaves.left.and.right", text: "Your relay lives on this device and sends your posts out to public relays so people can see them.")
                    explainerRow(icon: "photo.on.rectangle", text: "Your vault does the same for photos and videos: they're kept here and copied to your media servers.")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(WizardColors.borderSubtle, lineWidth: 1)
                )
                .opacity(showContent ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(1.2), value: showContent)

                Text("Next, a short guide helps you find people to follow.")
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .opacity(showContent ? 1 : 0)
                    .animation(WizardAnimations.fadeIn.delay(1.3), value: showContent)
            }

            Spacer()

            #if os(macOS)
            Text(String(localized: "setup.complete.menuBarHint"))
                .font(.appSystem(size: 14))
                .foregroundColor(WizardColors.accentPrimary.opacity(0.8))
                .opacity(showContent ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(1.5), value: showContent)
            #endif

            // Launch button with pulse
            WizardPrimaryButton(title: isNewUser ? "Start Exploring" : String(localized: "setup.complete.launch"), action: onLaunch)
                .shadow(color: buttonPulse ? WizardColors.accentGlow : .clear, radius: buttonPulse ? 16 : 8)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(1.6), value: showContent)

            Spacer().frame(height: 16)
        }
        .onAppear {
            showContent = true

            // The expanding rings are a pure decorative flourish — no state they
            // carry is otherwise communicated — so Reduce Motion drops the
            // animation outright rather than replacing it with a fade, the same
            // treatment `Motion.ambientPulse` gives the button pulse below.
            if Motion.isReduced {
                ringOpacity = 0
                ring2Opacity = 0
                ring3Opacity = 0
            } else {
                // Ring 1
                withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                    ringScale = 2.0
                    ringOpacity = 0
                }
                // Ring 2
                withAnimation(.easeOut(duration: 0.8).delay(0.35)) {
                    ring2Scale = 2.0
                    ring2Opacity = 0
                }
                // Ring 3
                withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                    ring3Scale = 2.0
                    ring3Opacity = 0
                }
            }

            // Button pulse loop
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let loop = Motion.ambientPulse else { return }
                withAnimation(loop) { buttonPulse = true }
            }

            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                FloatingArrowController.shared.show()
            }
            #endif
        }
    }

    private func explainerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func completeBullet(icon: String, text: String, color: Color, delay: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.appSystem(size: 18))
            Text(text)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textPrimary)
        }
        .opacity(showContent ? 1 : 0)
        .offset(x: showContent ? 0 : -20)
        .animation(WizardAnimations.springEnter.delay(delay), value: showContent)
    }
}
