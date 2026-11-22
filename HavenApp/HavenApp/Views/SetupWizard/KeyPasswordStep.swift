import SwiftUI

// MARK: - Step 10: Lock it in (New to Nostr path)

/// The last key step (setup screens r3, Way 1c): the password that encrypts
/// the new nsec (NIP-49), under the VaultMark with the key in its keyhole.
/// Its own page so the fields sit above the keyboard without scrolling.
struct KeyPasswordStep: View {
    @Binding var nsecPassword: String
    let onContinue: () -> Void

    @State private var keyPassword = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @FocusState private var focusedField: Field?

    private enum Field { case password, confirm }

    /// With the keyboard up the icon and subtitle step aside, so the fields,
    /// the warning and Continue all stay above it on an iPhone SE.
    private var isTyping: Bool { focusedField != nil }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: isTyping ? 4 : 20)

            VStack(spacing: 10) {
                if !isTyping {
                    KeyStepsStrip(current: .lock)
                    vaultMark
                        .transition(.opacity)
                }
                Text("Lock it in")
                    .font(.appSystem(size: 28, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if !isTyping {
                    Text("A password locks your key in the vault on this device. It never leaves it, and we can't reset it.")
                        .font(.appSystem(size: 15))
                        .foregroundColor(WizardColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    passwordField("Password (minimum 8 characters)", text: $keyPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .confirm }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .background(WizardColors.bgElevated)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WizardColors.borderSubtle, lineWidth: 1)
                )

                passwordField("Confirm password", text: $confirmPassword)
                    .focused($focusedField, equals: .confirm)
                    .submitLabel(.continue)
                    .onSubmit(validateAndContinue)
                    .padding(12)
                    .background(WizardColors.bgElevated)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(WizardColors.borderSubtle, lineWidth: 1)
                    )

                if !keyPassword.isEmpty && keyPassword.count < 8 {
                    validationMessage("Password must be at least 8 characters")
                }
                if !confirmPassword.isEmpty && keyPassword != confirmPassword {
                    validationMessage("Passwords do not match")
                }
            }

            // Above the warning so it stays above the keyboard while typing;
            // the warning was already read before a field took focus.
            WizardPrimaryButton(title: "Lock", action: validateAndContinue, disabled: !isPasswordValid)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.appSystem(size: 16))
                    .foregroundColor(WizardColors.accentPrimary)
                    .accessibilityHidden(true)
                Text("Write this password down and keep it with your secret key.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(WizardColors.accentPrimary.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(WizardColors.borderActive, lineWidth: 1)
            )
            .accessibilityElement(children: .combine)

            Spacer()
        }
        .animation(WizardAnimations.springGentle, value: isTyping)
    }

    /// The VaultMark arch with the key sitting in its glowing keyhole.
    private var vaultMark: some View {
        ZStack(alignment: .bottom) {
            Image("VaultMark")
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 92 * 0.2237, style: .continuous))
            Image(systemName: "key.horizontal.fill")
                .font(.appSystem(size: 22, weight: .bold))
                .foregroundStyle(WizardColors.accentGradient)
                .shadow(color: WizardColors.accentGlow, radius: 8)
                .offset(y: 6)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func passwordField(_ placeholder: String, text: Binding<String>) -> some View {
        Group {
            if showPassword {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .font(.appSystem(size: 14))
        .foregroundColor(WizardColors.textPrimary)
        .textFieldStyle(.plain)
        .disableAutocorrection(true)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    private func validationMessage(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle")
                .font(.appSystem(size: 12))
            Text(text)
                .font(.appSystem(size: 12))
        }
        .foregroundColor(WizardColors.error)
    }

    private var isPasswordValid: Bool {
        keyPassword.count >= 8 && keyPassword == confirmPassword
    }

    private func validateAndContinue() {
        guard isPasswordValid else { return }
        nsecPassword = keyPassword
        onContinue()
    }
}
