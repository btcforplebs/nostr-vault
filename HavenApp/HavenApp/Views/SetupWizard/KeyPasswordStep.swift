import SwiftUI

// MARK: - Step 10: Protect Your Key (New to Nostr path)

/// The password that encrypts the new nsec (NIP-49). Its own page so the
/// fields sit above the keyboard without scrolling.
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

            VStack(spacing: 8) {
                if !isTyping {
                    Image(systemName: "lock.shield.fill")
                        .font(.appSystem(size: 40))
                        .foregroundStyle(WizardColors.accentGradient)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                Text("Protect Your Key")
                    .font(.appSystem(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                if !isTyping {
                    Text("Choose a password to lock your secret key on this device.")
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
            WizardPrimaryButton(title: "Continue", action: validateAndContinue, disabled: !isPasswordValid)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.appSystem(size: 16))
                    .foregroundColor(WizardColors.accentPrimary)
                    .accessibilityHidden(true)
                Text("Nobody can reset this password or recover your secret key for you, not even us. Write both down.")
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
