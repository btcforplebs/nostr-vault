import SwiftUI

// MARK: - Step 9: Your keys (New to Nostr path)

/// The new keypair, made when New to Nostr was picked (NewKeyPair): both
/// keys explained, and the nsec backed up before the user can move on. The
/// password is its own step (10). The "Welcome to Nostr" cards that used to
/// come first were dropped (setup screens r3, Logen 2026-11-22).
struct NostrIntroStep: View {
    @Binding var npub: String
    @Binding var nsec: String
    let onContinue: () -> Void

    @State private var appeared = false
    @State private var error: String?
    @State private var savedKey = false
    @State private var copiedKey: String?

    /// Derived from the binding, not local state, so Back from the password
    /// step shows the same key instead of offering to generate a new one.
    private var hasKeys: Bool { !nsec.isEmpty }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: hasKeys ? 4 : 20)

            if hasKeys {
                keysContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                introContent
            }

            Spacer()
        }
        .onAppear { appeared = true }
    }

    /// Only seen if making the key failed when New to Nostr was picked.
    @ViewBuilder
    private var introContent: some View {
        if let errorText = error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(errorText)
                    .font(.appSystem(size: 13))
            }
            .foregroundColor(WizardColors.error)
        }

        WizardPrimaryButton(title: "Make My Key", action: generateKeys)
    }

    private var keysContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Your Keys")
                    .font(.appSystem(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                Text("Two keys replace a username and password.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            keyCard(
                icon: "person.crop.circle",
                title: "Public key",
                caption: "Your name on Nostr. Share it freely.",
                value: npub,
                isSecret: false
            )

            keyCard(
                icon: "key.fill",
                title: "Secret key",
                caption: "Your password to Nostr. Anyone who has it can post as you, so never share it.",
                value: nsec,
                isSecret: true
            )

            Button {
                savedKey.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: savedKey ? "checkmark.square.fill" : "square")
                        .font(.appSystem(size: 20))
                        .foregroundColor(savedKey ? WizardColors.accentPrimary : WizardColors.textMuted)
                    Text("I saved my secret key")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I saved my secret key")
            .accessibilityValue(savedKey ? "Checked" : "Not checked")

            WizardPrimaryButton(title: "Continue", action: onContinue, disabled: !savedKey)
        }
    }

    private func keyCard(icon: String, title: String, caption: String, value: String, isSecret: Bool) -> some View {
        WizardGlassCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.appSystem(size: 15))
                        .foregroundColor(isSecret ? WizardColors.accentPrimary : WizardColors.textSecondary)
                    Text(title)
                        .font(.appSystem(size: 16, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                    Spacer(minLength: 0)
                    Text(copiedKey == value ? "Copied" : "Copy")
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(copiedKey == value ? WizardColors.success : WizardColors.accentPrimary)
                }

                Text(caption)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(value)
                    .font(.appSystem(size: 12, design: .monospaced))
                    .foregroundColor(isSecret ? WizardColors.accentPrimary : WizardColors.textSecondary)
                    // The npub only needs recognising; the nsec has to be
                    // readable in full to write it down.
                    .lineLimit(isSecret ? nil : 1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(WizardColors.bgElevated)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(WizardColors.borderSubtle, lineWidth: 1)
                    )

                if isSecret {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.appSystem(size: 12))
                        Text("Nobody can recover it for you, not even us.")
                            .font(.appSystem(size: 12))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(WizardColors.textPrimary.opacity(0.85))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { copy(value) }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to copy")
        .accessibilityAddTraits(.isButton)
    }

    private func copy(_ value: String) {
        // The nsec card's copy stays on this device and expires; the npub is public.
        if value.lowercased().hasPrefix("nsec1") {
            PlatformClipboard.copySecret(value)
        } else {
            PlatformClipboard.copy(value)
        }
        withAnimation(WizardAnimations.springGentle) { copiedKey = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedKey == value {
                withAnimation(WizardAnimations.springGentle) { copiedKey = nil }
            }
        }
    }

    private func generateKeys() {
        guard let pair = NewKeyPair.generate() else {
            error = "Key generation failed"
            return
        }
        error = nil
        withAnimation(WizardAnimations.springBounce) {
            npub = pair.npub
            nsec = pair.nsec
        }
    }
}
