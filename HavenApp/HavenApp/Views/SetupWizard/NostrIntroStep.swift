import SwiftUI

// MARK: - Step 9: Nostr Intro (New to Nostr path)

/// What Nostr is, then the new keypair: both keys explained, and the nsec
/// backed up before the user can move on. The password is its own step (10)
/// so neither page needs scrolling.
struct NostrIntroStep: View {
    @Binding var npub: String
    @Binding var nsec: String
    let onContinue: () -> Void

    @State private var appeared = false
    @State private var isGenerating = false
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

    @ViewBuilder
    private var introContent: some View {
        // Card 1: What is Nostr
        WizardGlassCard(isSelected: false) {
            VStack(spacing: 12) {
                Text("Welcome to Nostr")
                    .font(.appSystem(size: 20, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Nostr is an open social protocol. You own your identity through a cryptographic keypair -- no company controls your account. Your posts are broadcast to relays and can be read by anyone.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(WizardAnimations.springEnter.delay(0.15), value: appeared)

        // Card 2: Why Nostr Vault is unique
        WizardGlassCard(isSelected: false) {
            VStack(spacing: 12) {
                Text("Your Personal Archive")
                    .font(.appSystem(size: 20, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Nostr Vault runs a HAVEN relay right on your device. Every note, message, and media file you interact with is archived locally. Your data stays with you -- not on someone else's server.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

        if let errorText = error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(errorText)
                    .font(.appSystem(size: 13))
            }
            .foregroundColor(WizardColors.error)
        }

        WizardPrimaryButton(title: "Create My Account", action: generateKeys)
            .disabled(isGenerating)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(WizardAnimations.springEnter.delay(0.45), value: appeared)

        if isGenerating {
            ProgressView()
                .tint(WizardColors.accentPrimary)
        }
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
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
        withAnimation(WizardAnimations.springGentle) { copiedKey = value }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedKey == value {
                withAnimation(WizardAnimations.springGentle) { copiedKey = nil }
            }
        }
    }

    private func generateKeys() {
        isGenerating = true
        error = nil

        guard let resultCStr = GenerateKeyPairC() else {
            error = "Key generation failed"
            isGenerating = false
            return
        }
        let result = String(cString: resultCStr)
        let parts = result.split(separator: ":")
        guard parts.count == 2 else {
            error = "Key generation returned invalid format"
            isGenerating = false
            return
        }
        let sk = String(parts[0])
        let pk = String(parts[1])

        var newNpub: String?
        var newNsec: String?
        if let pubData = Bech32.hexToData(pk) {
            newNpub = Bech32.encode(hrp: "npub", data: pubData)
        }
        if let secData = Bech32.hexToData(sk) {
            newNsec = Bech32.encode(hrp: "nsec", data: secData)
        }

        withAnimation(WizardAnimations.springBounce) {
            if let newNpub { npub = newNpub }
            if let newNsec { nsec = newNsec }
        }
        isGenerating = false
    }
}
