import SwiftUI

/// After a copy: "Add these accounts here too?" Lists the accounts the
/// other device brought over (name and short npub) and adds only the ones
/// the person ticks, look-only (public key only). Nothing is ticked to
/// start with. Shown at the end of setup's copy step, and as a sheet from
/// the app's root when a copy or catch-up finishes later.
struct CopyAccountsAskView: View {
    let accounts: [CopyAccounts.Account]
    /// The ticked accounts (empty for Skip).
    let onAnswer: ([CopyAccounts.Account]) -> Void

    @State private var ticked: Set<String> = []

    static let title = "Add your other accounts?"
    static let message = "These accounts came over with the copy. Tick the ones you want here too. "
        + "They are added look-only: just the public key, no private key or sign-in. "
        + "Their notes are already in this vault either way."

    private var chosen: [CopyAccounts.Account] { accounts.filter { ticked.contains($0.npub) } }

    var body: some View {
        VStack(spacing: 16) {
            Text(Self.title)
                .font(.appSystem(size: 20, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(Self.message)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(accounts) { a in row(a) }
                }
            }
            .frame(maxHeight: 320)
            WizardPrimaryButton(title: chosen.isEmpty ? "Add selected" : "Add \(chosen.count)",
                                action: { onAnswer(chosen) }, disabled: chosen.isEmpty)
                .disabled(chosen.isEmpty)
            Button("Skip") { onAnswer([]) }
                .buttonStyle(.plain)
                .foregroundColor(WizardColors.textSecondary)
                .frame(minHeight: 44)
        }
        .padding(20)
    }

    private func row(_ a: CopyAccounts.Account) -> some View {
        let on = ticked.contains(a.npub)
        return Button {
            if on { ticked.remove(a.npub) } else { ticked.insert(a.npub) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 22))
                    .foregroundColor(on ? WizardColors.accentPrimary : WizardColors.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name.isEmpty ? MeshPairing.shortAddress(a.npub) : a.name)
                        .font(.appSystem(size: 16, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(1)
                    if !a.name.isEmpty {
                        Text(MeshPairing.shortAddress(a.npub))
                            .font(.appSystem(size: 13, design: .monospaced))
                            .foregroundColor(WizardColors.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The ask as a sheet over the app, once setup is done, whenever a copy or
/// catch-up left accounts to ask about.
struct CopyAccountsAskSheet: ViewModifier {
    @ObservedObject private var sync = CopyAccountsSync.shared
    let enabled: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { enabled && !sync.offered.isEmpty },
            set: { shown in if !shown, !sync.offered.isEmpty { sync.answer(ticked: []) } }
        )) {
            CopyAccountsAskView(accounts: sync.offered) { sync.answer(ticked: $0) }
                .background(WizardColors.bgPrimary)
                .preferredColorScheme(.dark)
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    func copyAccountsAsk(enabled: Bool) -> some View { modifier(CopyAccountsAskSheet(enabled: enabled)) }
}
