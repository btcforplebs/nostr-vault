import SwiftUI

/// The visible Copy pill next to Show on the key steps (Logen 2026-11-22:
/// "This key is you" and "Back up your key" each need a Copy you can see).
/// The key goes on the clipboard for `PlatformClipboard.secretLifetime`
/// (60 s, this device only); the pill reads "Copied" for that long.
struct KeyCopyButton: View {
    let nsec: String
    @Binding var copied: Bool

    var body: some View {
        Button(action: copy) {
            Label(copied ? "Copied" : "Copy my key", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(copied ? WizardColors.success : WizardColors.accentPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(Capsule().fill((copied ? WizardColors.success : WizardColors.accentPrimary).opacity(0.12)))
                .overlay(Capsule().stroke(copied ? WizardColors.success.opacity(0.5) : WizardColors.borderActive, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Secret key copied" : "Copy secret key")
    }

    private func copy() {
        PlatformClipboard.copySecret(nsec)
        withAnimation(WizardAnimations.springGentle) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + PlatformClipboard.secretLifetime) {
            withAnimation(WizardAnimations.springGentle) { copied = false }
        }
    }
}
