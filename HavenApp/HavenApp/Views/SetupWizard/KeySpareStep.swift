import SwiftUI

// MARK: - Step 18: Keep a spare (New to Nostr path)

/// The second key step (setup screens r3, Way 1b): the key with lines down
/// to two spares, a paper card and a copy. Print a card is the big button,
/// Copy the small one. Next waits for "I saved my secret key", which only
/// the user ticks: a print job may not reach paper, and a copy clears from
/// the clipboard after 60 s, so neither counts as a spare on its own.
/// Save to Passwords is a follow-up (KeySpare).
struct KeySpareStep: View {
    let npub: String
    let nsec: String
    let name: String
    let onNext: () -> Void

    @State private var printed = false
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

            Text(copied
                 ? "Copied. Paste it somewhere safe within a minute; then the clipboard clears."
                 : "Print it on paper. Don't save it to Photos, Files or iCloud.")
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            savedCheck

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                if !printed && !savedKey {
                    WizardPrimaryButton(title: "Print a card", action: printCard)
                } else {
                    WizardPrimaryButton(title: "Next", action: onNext, disabled: !savedKey)
                }
                HStack(spacing: 6) {
                    if printed || savedKey {
                        smallLink("Print again", action: printCard)
                        Text("·").foregroundColor(WizardColors.textMuted).accessibilityHidden(true)
                    }
                    smallLink(copied ? "Copied" : "Copy it instead", action: copy)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
    }

    /// The key, wired down to the two spares. Only paper turns green: a copy
    /// leaves the clipboard after 60 s, so it never shows as a finished spare.
    private var picture: some View {
        VStack(spacing: 0) {
            Image(systemName: "key.horizontal.fill")
                .font(.appSystem(size: 40, weight: .bold))
                .foregroundStyle(WizardColors.accentGradient)
                .shadow(color: WizardColors.accentGlow, radius: 12)
                .frame(height: 52)
            HStack(spacing: 140) {
                wire(done: printed)
                wire(done: false)
            }
            .frame(height: 30)
            HStack(spacing: 14) {
                tile(icon: "printer.fill", label: "On paper", done: printed)
                tile(icon: "doc.on.doc.fill", label: "Copy", done: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spareSummary)
    }

    private var spareSummary: String {
        printed ? "Spare printed" : "No spare yet"
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

    private func printCard() {
        KeySpare.printCard(name: name, npub: npub, nsec: nsec) { done in
            guard done else { return }
            withAnimation(WizardAnimations.springGentle) { printed = true }
        }
    }

    private func copy() {
        PlatformClipboard.copySecret(nsec)
        withAnimation(WizardAnimations.springGentle) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { copied = false }
    }
}
