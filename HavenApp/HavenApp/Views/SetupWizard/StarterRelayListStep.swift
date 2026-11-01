import SwiftUI

// MARK: - Step 17: Choose your relays

/// Setup's relay list step, on the create-account path only. A brand-new
/// key has no relay list (kind 10002), and without one other apps can't
/// find its posts. The person chooses the servers; we only recommend
/// (Logen 2026-11-01): the list starts empty, the recommended servers are
/// suggestions with one "Use recommended" button, and any server can be
/// added or removed. Confirm publishes exactly what was picked, once setup
/// has stored the key; Skip publishes nothing. Rules: SetupRelayChoice.
/// Android: the twin step should follow the same rules.
struct StarterRelayListStep: View {
    /// The relays picked (empty = publish nothing).
    let onContinue: ([String]) -> Void

    @State private var choice: SetupRelayChoice
    @State private var typed = ""
    @State private var typedInvalid = false
    @State private var appeared = false

    init(recommended: [String], picked: [String] = [], onContinue: @escaping ([String]) -> Void) {
        self.onContinue = onContinue
        _choice = State(initialValue: SetupRelayChoice(recommended: recommended, picked: picked))
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 8)
            VStack(spacing: 8) {
                Text("Choose where your posts go")
                    .font(.appSystem(size: 22, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                Text("Other apps find your posts on these servers. We suggest a few, and you can add any server you like. Nothing is shared until you confirm.")
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            WizardGlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Your servers")
                    if choice.chosen.isEmpty {
                        Text("None yet. Use the recommended servers or add your own.")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(choice.chosen, id: \.self) { url in
                        relayRow(url, icon: "minus.circle.fill", tint: WizardColors.error,
                                 label: "Remove \(RelayMatrix.label(url))") {
                            withAnimation(WizardAnimations.springGentle) { choice.remove(url) }
                        }
                    }
                    addField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !choice.hasAllRecommended {
                WizardGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            sectionLabel("Recommended")
                            Spacer()
                            Button("Use recommended") {
                                withAnimation(WizardAnimations.springGentle) { choice.useRecommended() }
                            }
                            .buttonStyle(.plain)
                            .font(.appSystem(size: 14, weight: .semibold))
                            .foregroundColor(WizardColors.accentPrimary)
                        }
                        ForEach(choice.suggestions, id: \.self) { url in
                            relayRow(url, icon: "plus.circle.fill", tint: WizardColors.accentPrimary,
                                     label: "Add \(RelayMatrix.label(url))") {
                                withAnimation(WizardAnimations.springGentle) { _ = choice.add(url) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: confirmTitle, action: { onContinue(choice.chosen) },
                                    disabled: choice.chosen.isEmpty)
                WizardSkipLink(title: "Skip for now") { onContinue([]) }
            }
            .padding(.top, 4)
            Spacer(minLength: 8)
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.fadeIn, value: appeared)
        .onAppear { appeared = true }
    }

    private var confirmTitle: String {
        switch choice.chosen.count {
        case 0: return "Pick at least one server"
        case 1: return "Use this server"
        default: return "Use these \(choice.chosen.count) servers"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 13, weight: .semibold))
            .foregroundColor(WizardColors.textSecondary)
    }

    private func relayRow(_ url: String, icon: String, tint: Color, label: String,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(WizardColors.textMuted)
                .accessibilityHidden(true)
            Text(RelayMatrix.label(url))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: action) {
                Image(systemName: icon)
                    .font(.appSystem(size: 20))
                    .foregroundColor(tint)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("relay.example.com", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textPrimary)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(addTyped)
                    .onChange(of: typed) { _, _ in typedInvalid = false }
                    .padding(10)
                    .background(WizardColors.bgElevated)
                    .cornerRadius(10)
                Button("Add", action: addTyped)
                    .buttonStyle(.plain)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(typed.isEmpty ? WizardColors.textMuted : WizardColors.accentPrimary)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if typedInvalid {
                Text(choice.contains(SetupRelayChoice.cleaned(typed) ?? "\u{0}")
                     ? "That server is already on your list."
                     : "That isn't a server address. Try relay.example.com or wss://relay.example.com.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addTyped() {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if withAnimation(WizardAnimations.springGentle, { choice.add(typed) }) {
            typed = ""
        } else {
            typedInvalid = true
        }
    }
}
