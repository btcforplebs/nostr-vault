import SwiftUI

/// A Vault line that tagged several of your accounts: tapping it asks which
/// account to open it as, so a reply or reaction from the opened note signs
/// with the account you chose (Logen 2026-11-05). The list's account switch
/// and open path then runs as for any other account's line.
/// Android twin: a picker sheet before `openLineAs` (not built yet).
struct VaultAccountPickButton<Label: View>: View {
    /// The line's accounts, in switcher order.
    let accounts: [String]
    let name: (String) -> String
    let onPick: (String) -> Void
    @ViewBuilder var label: Label

    @State private var asking = false

    var body: some View {
        Button { asking = true } label: { label }
            .buttonStyle(.plain)
            .confirmationDialog("Reply or react as", isPresented: $asking, titleVisibility: .visible) {
                ForEach(accounts, id: \.self) { hex in
                    Button(name(hex)) { onPick(hex) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
