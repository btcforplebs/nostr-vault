import SwiftUI

// MARK: - Step 17: Your starter relay list

/// Setup's relay list step, on the create-account path only (Logen
/// 2026-10-31, 2A). A brand-new key has no relay list (kind 10002), and
/// without one other apps can't find its posts, so setup offers the app's
/// starter list: publish it, edit it first, or skip and publish nothing.
/// Nothing is published here: the wizard publishes the chosen list once
/// setup has stored the key. Android shows the same step.
struct StarterRelayListStep: View {
    /// The app's starter relays (wss, reachable by others).
    let starter: [String]
    /// The relays to publish, or nil to publish nothing.
    let onFinish: ([String]?) -> Void

    @State private var relays: [String] = []
    @State private var editing = false
    @State private var newRelay = ""
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 12)
            VStack(spacing: 8) {
                Text("Your relay list")
                    .font(.appSystem(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Other apps look here to find your posts. Publish this starter list with your new account, edit it first, or skip it. You can change it later in Settings > Relays.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WizardGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    if relays.isEmpty {
                        Text("No relays. Add one, or skip.")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                    }
                    ForEach(relays, id: \.self) { url in
                        HStack(spacing: 10) {
                            if editing {
                                Button {
                                    relays.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundColor(WizardColors.error)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(RelayMatrix.label(url))")
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(WizardColors.accentPrimary)
                                    .accessibilityHidden(true)
                            }
                            Text(RelayMatrix.label(url))
                                .font(.appSystem(size: 15))
                                .foregroundColor(WizardColors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    }
                    if editing {
                        HStack(spacing: 8) {
                            TextField("relay.example.com", text: $newRelay)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                #endif
                                .autocorrectionDisabled(true)
                                .onSubmit(add)
                            Button("Add", action: add)
                                .disabled(RelayMatrix.relayURL(from: newRelay) == nil)
                        }
                        .font(.appSystem(size: 15))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: "Publish This List", action: { onFinish(relays) }, disabled: relays.isEmpty)
                WizardSkipLink(title: editing ? "Done Editing" : "Edit") { editing.toggle() }
                WizardSkipLink(title: "Skip, publish nothing") { onFinish(nil) }
            }
            .padding(.top, 8)
            Spacer(minLength: 8)
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.fadeIn, value: appeared)
        .onAppear {
            if !appeared { relays = starter }
            appeared = true
        }
    }

    private func add() {
        guard let url = RelayMatrix.relayURL(from: newRelay),
              !relays.contains(where: { RelayMatrix.key($0) == RelayMatrix.key(url) }) else { return }
        relays.append(url)
        newRelay = ""
    }
}
