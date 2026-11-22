import SwiftUI

// MARK: - Step 9: This key is you (New to Nostr path)

/// The first key step (setup screens r3, Way 1a): your photo and name, "=",
/// and the key. The key was made when Create an account was picked
/// (NewKeyPair); the secret stays hidden until Show, and Copy puts it on the
/// clipboard for 60 s. Backing it up is the next step (KeyBackupStep), the password the one after (KeyPasswordStep).
struct KeyIsYouStep: View {
    @Binding var npub: String
    @Binding var nsec: String
    let name: String
    let photoJPEG: Data?
    /// Make My Key's key, so the wizard keeps it for the rest of the run.
    let onMade: ((npub: String, nsec: String)) -> Void
    let onNext: () -> Void

    @State private var shown = false
    @State private var copied = false
    @State private var error: String?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            KeyStepsStrip(current: .key).padding(.top, 8)

            Text("This key is you")
                .font(.appSystem(size: 28, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            equation
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)
                .animation(WizardAnimations.springBounce.delay(0.1), value: appeared)

            if nsec.isEmpty {
                if let error {
                    Text(error).font(.appSystem(size: 14)).foregroundColor(WizardColors.error)
                }
                WizardPrimaryButton(title: "Make My Key", action: generate)
            } else {
                secretCard
                Text("Anyone with it can post as you. Nobody can get it back for you, not even us.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                WizardPrimaryButton(title: "Next", action: onNext)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 560)
        .onAppear { appeared = true }
    }

    /// You = key.
    private var equation: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(WizardColors.bgElevated)
                    if let preview = photoJPEG.flatMap(EditProfileStep.previewImage) {
                        Image(decorative: preview, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .font(.appSystem(size: 38))
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay(Circle().stroke(WizardColors.borderActive, lineWidth: 2))
                Text(displayName)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }
            Text("=")
                .font(.appSystem(size: 40, weight: .bold))
                .foregroundColor(WizardColors.textMuted)
            VStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.appSystem(size: 56, weight: .bold))
                    .foregroundStyle(WizardColors.accentGradient)
                    .shadow(color: WizardColors.accentGlow, radius: 14)
                    .frame(width: 92, height: 92)
                Text("Your key")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName) equals your key")
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    private var secretCard: some View {
        WizardGlassCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Secret key", systemImage: "key.fill")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                    Spacer()
                    Button(shown ? "Hide" : "Show") {
                        withAnimation(WizardAnimations.springGentle) { shown.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(WizardColors.accentPrimary)
                    .frame(minHeight: 44)
                    .accessibilityLabel(shown ? "Hide secret key" : "Show secret key")
                    KeyCopyButton(nsec: nsec, copied: $copied)
                }
                Text(shown ? nsec : String(repeating: "•", count: 24))
                    .font(.appSystem(size: 13, design: .monospaced))
                    .foregroundColor(shown ? WizardColors.accentPrimary : WizardColors.textMuted)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(WizardColors.bgElevated)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WizardColors.borderSubtle, lineWidth: 1))
                    .privacySensitive()
                    .keySnapshotCover()
                    .accessibilityLabel(shown ? "Secret key shown" : "Secret key hidden")
            }
        }
    }

    private func generate() {
        guard let pair = NewKeyPair.generate() else {
            error = "Key generation failed"
            return
        }
        error = nil
        npub = pair.npub
        nsec = pair.nsec
        onMade(pair)
    }
}
