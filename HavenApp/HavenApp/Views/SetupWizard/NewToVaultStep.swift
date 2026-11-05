import SwiftUI

// MARK: - New to Nostr Vault?

/// Setup's second question, for people who already use Nostr
/// (NewToVaultQuestion). Yes brings their notes from their relays; No copies
/// from their other vault, falling back to the relays when it can't be
/// reached. A backup zip is restored from the Vault tab, not here.
struct NewToVaultStep: View {
    /// Yes: on to the relay import.
    let onRelays: () -> Void
    /// No: the two scans, then the copy (OtherVaultCopy).
    let onCopyFromOtherVault: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text(NewToVaultQuestion.title)
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(NewToVaultQuestion.subtitle)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)

            WizardPrimaryButton(title: NewToVaultQuestion.yes, action: onRelays)
            Button(action: onCopyFromOtherVault) {
                Text(OtherVaultCopy.button)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .frame(maxWidth: isIOSDevice ? .infinity : nil, minHeight: 44)
                    .padding(.horizontal, isIOSDevice ? 0 : 32)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(OtherVaultCopy.smallPrint)
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
