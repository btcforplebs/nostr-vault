import SwiftUI

// MARK: - Step 18: Keep a spare (New to Nostr path)

/// The second key step (setup screens r3, Way 1b): the key with lines down
/// to two spares, written on paper by hand or copied. Show reveals the key
/// to write down; Copy puts it on the clipboard for 60 s. Nothing is
/// printed: Logen 2026-11-22 dropped printing from every key flow (a print
/// panel can save the key as a PDF or image). Next waits for "I saved my
/// secret key", which only the user ticks.
struct KeyBackupStep: View {
    let nsec: String
    let onNext: () -> Void

    @State private var shown = false
    @State private var copied = false
    @State private var savedKey = false

    var body: some View {
        VStack(spacing: 22) {
            KeyStepsStrip(current: .spare).padding(.top, 8)

            Text("Keep a spare")
                .font(.appSystem(size: 28, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            picture

            Text("Lose this phone and the spare is your only way back in.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            secretRow

            Text(copied
                 ? "Copied. Paste it somewhere safe within a minute; then the clipboard clears."
                 : "Write it down on paper. Don't save it to Photos, Files or iCloud.")
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            savedCheck

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                WizardPrimaryButton(title: "Next", action: onNext, disabled: !savedKey)
                smallLink(copied ? "Copied" : "Copy my key", action: copy)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
    }

    /// The key, wired down to the two spares. Neither turns green: the app
    /// can't see paper, and a copy leaves the clipboard after 60 s.
    private var picture: some View {
        VStack(spacing: 0) {
            Image(systemName: "key.horizontal.fill")
                .font(.appSystem(size: 40, weight: .bold))
                .foregroundStyle(WizardColors.accentGradient)
                .shadow(color: WizardColors.accentGlow, radius: 12)
                .frame(height: 52)
            HStack(spacing: 140) {
                wire(done: false)
                wire(done: false)
            }
            .frame(height: 30)
            HStack(spacing: 14) {
                tile(icon: "pencil.line", label: "On paper", done: false)
                tile(icon: "doc.on.doc.fill", label: "Copy", done: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keep a spare on paper or copy it")
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

    private func tile(icon: String, label: String, done: Bool) -> some View {
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
            .stroke(done ? WizardColors.success.opacity(0.6) : WizardColors.borderSubtle, lineWidth: done ? 2 : 1))
    }

    private var savedCheck: some View {
        Button { savedKey.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: savedKey ? "checkmark.square.fill" : "square")
                    .font(.appSystem(size: 20))
                    .foregroundColor(savedKey ? WizardColors.accentPrimary : WizardColors.textMuted)
                Text("I saved my secret key")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textPrimary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("I saved my secret key")
        .accessibilityValue(savedKey ? "Checked" : "Not checked")
    }

    private func smallLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.appSystem(size: 15, weight: .medium))
            .foregroundColor(WizardColors.accentPrimary)
            .frame(minHeight: 44)
    }

    // MARK: Actions

    private func copy() {
        PlatformClipboard.copySecret(nsec)
        withAnimation(WizardAnimations.springGentle) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { copied = false }
    }
}
