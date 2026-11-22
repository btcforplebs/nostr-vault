import SwiftUI

// MARK: - Step 18: Back up your key (New to Nostr path)

/// The second key step (setup screens r3, Way 1b; renamed from "Keep a
/// spare", Logen 2026-11-22): the key with lines down to two backups, on
/// paper or copied. Both tiles are buttons: On paper reveals the key to write
/// down, Copy puts it on the clipboard for 60 s. On the 12 mini the old Copy was a small link under Next, below the
/// fold, while the Copy tile looked tappable but wasn't. Nothing is printed
/// (Logen 2026-11-22). Next waits for "I backed up my key", which only the
/// user ticks.
struct KeyBackupStep: View {
    let nsec: String
    let onNext: () -> Void

    @State private var shown = false
    @State private var copied = false
    @State private var copyToken = UUID()
    @State private var savedKey = false

    var body: some View {
        VStack(spacing: 16) {
            KeyStepsStrip(current: .backup).padding(.top, 8)

            Text("Back up your key")
                .font(.appSystem(size: 28, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            picture

            Text("Write your key down on paper and keep it somewhere safe. If you lose this device, your backup is the only way back in.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            secretRow

            Text(copied
                 ? "Copied. Paste it somewhere safe within a minute; then the clipboard clears."
                 : "Don't save it to Photos, Files or iCloud.")
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            savedCheck

            Spacer(minLength: 8)

            WizardPrimaryButton(title: "Next", action: onNext, disabled: !savedKey)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
    }

    /// The key, wired down to the two backups. Paper never turns green (the
    /// app can't see paper); Copy shows Copied while the clipboard holds it.
    private var picture: some View {
        VStack(spacing: 0) {
            Image(systemName: "key.horizontal.fill")
                .font(.appSystem(size: 40, weight: .bold))
                .foregroundStyle(WizardColors.accentGradient)
                .shadow(color: WizardColors.accentGlow, radius: 12)
                .frame(height: 52)
                .accessibilityHidden(true)
            HStack(spacing: 140) {
                wire(done: false)
                wire(done: false)
            }
            .frame(height: 30)
            .accessibilityHidden(true)
            HStack(spacing: 14) {
                tile(icon: "pencil.line", label: "On paper", done: false) {
                    withAnimation(WizardAnimations.springGentle) { shown = true }
                }
                .accessibilityLabel("On paper: show the key to write it down")
                tile(icon: "doc.on.doc.fill", label: copied ? "Copied" : "Copy my key", done: copied) {
                    copy()
                }
                .accessibilityLabel(copied ? "Secret key copied" : "Copy secret key")
            }
        }
    }

    /// The key, hidden until Show, to write down by hand.
    private var secretRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(shown ? nsec : String(repeating: "•", count: 24))
                .font(.appSystem(size: 13, design: .monospaced))
                .foregroundColor(shown ? WizardColors.accentPrimary : WizardColors.textMuted)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
                .keySnapshotCover()
                .accessibilityLabel(shown ? "Secret key shown" : "Secret key hidden")
            Button(shown ? "Hide" : "Show") {
                withAnimation(WizardAnimations.springGentle) { shown.toggle() }
            }
            .buttonStyle(.plain)
            .font(.appSystem(size: 14, weight: .semibold))
            .foregroundColor(WizardColors.accentPrimary)
            .frame(minHeight: 32)
            .accessibilityLabel(shown ? "Hide secret key" : "Show secret key")
        }
        .padding(10)
        .background(WizardColors.bgElevated)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WizardColors.borderSubtle, lineWidth: 1))
    }

    private func wire(done: Bool) -> some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            .foregroundColor(done ? WizardColors.success : WizardColors.borderActive)
            .frame(width: 2)
    }

    private func tile(icon: String, label: String, done: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.appSystem(size: 26))
                    .foregroundColor(done ? WizardColors.success : WizardColors.accentPrimary)
                Text(label)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
            }
            .frame(width: 128, height: 92)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(done ? WizardColors.success.opacity(0.6) : WizardColors.borderActive, lineWidth: done ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var savedCheck: some View {
        Button { savedKey.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: savedKey ? "checkmark.square.fill" : "square")
                    .font(.appSystem(size: 20))
                    .foregroundColor(savedKey ? WizardColors.accentPrimary : WizardColors.textMuted)
                Text("I backed up my key")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textPrimary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("I backed up my key")
        .accessibilityValue(savedKey ? "Checked" : "Not checked")
    }

    // MARK: Actions

    private func copy() {
        PlatformClipboard.copySecret(nsec)
        let token = UUID()
        copyToken = token
        withAnimation(WizardAnimations.springGentle) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + PlatformClipboard.secretLifetime) {
            guard copyToken == token else { return }  // a later tap restarted the 60 s
            withAnimation(WizardAnimations.springGentle) { copied = false }
        }
    }
}
