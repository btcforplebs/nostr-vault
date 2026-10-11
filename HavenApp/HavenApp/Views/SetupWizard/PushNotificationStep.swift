import SwiftUI

// MARK: - Step 6b: Push Notifications (iOS only)

struct PushNotificationStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false
    @State private var dmEnabled = true
    @State private var zapEnabled = true
    @State private var mentionEnabled = true

    var body: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 40)

            Image(systemName: "bell.badge.fill")
                .font(.appSystem(size: 56))
                .foregroundColor(WizardColors.accentPrimary)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .offset(y: appeared ? 0 : -20)
                .animation(WizardAnimations.springBounce.delay(0.1), value: appeared)

            Text(String(localized: "setup.notifications.title"))
                .font(.appSystem(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            Text(String(localized: "setup.notifications.subtitle"))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.4), value: appeared)

            // Toggle cards
            VStack(spacing: 0) {
                notificationToggle(icon: "bubble.left.fill", label: String(localized: "setup.notifications.directMessages"), isOn: $dmEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "bolt.fill", label: String(localized: "setup.notifications.zaps"), isOn: $zapEnabled)
                Divider().background(WizardColors.borderSubtle).padding(.horizontal, 16)
                notificationToggle(icon: "at", label: String(localized: "setup.notifications.mentions"), isOn: $mentionEnabled)
            }
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.springEnter.delay(0.5), value: appeared)

            WizardPrimaryButton(title: String(localized: "setup.notifications.enable"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.notifications.skip")) { onSkip() }

            Spacer()
        }
        .onAppear { appeared = true }
    }

    private func notificationToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 16))
                .foregroundColor(WizardColors.accentPrimary)
                .frame(width: 24)
            Text(label)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .tint(WizardColors.accentPrimary)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
