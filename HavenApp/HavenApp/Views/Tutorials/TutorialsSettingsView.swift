import SwiftUI

/// Settings → Tutorials: every tutorial in this build, whether it's been
/// seen, and a Replay button. `onReplay` closes Settings and opens the
/// tutorial's page, where its card is waiting.
struct TutorialsSettingsView: View {
    var onReplay: (TutorialID) -> Void = { _ in }

    @ObservedObject private var center = TutorialCenter.shared
    @EnvironmentObject private var nostrService: NostrService
    @State private var confirmingReset = false

    private var account: String { nostrService.ownerHexPubkey }
    private var tutorials: [TutorialID] { TutorialID.allCases.filter(\.isAvailable) }

    var body: some View {
        Form {
            Section {
                ForEach(tutorials, id: \.self) { id in
                    row(id)
                }
            } footer: {
                Text("Each tutorial shows once, the first time you open its page. Skip any of them and replay it here.")
            }

            Section {
                Button("Show All Again", role: .destructive) { confirmingReset = true }
                    .disabled(account.isEmpty)
            } footer: {
                Text("Each tutorial shows again the next time you open its page. Your follows aren't changed.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Show all tutorials again?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Show All Again", role: .destructive) { center.resetAll(account: account) }
        }
    }

    private func row(_ id: TutorialID) -> some View {
        HStack(spacing: 12) {
            Image(systemName: id.symbolName)
                .foregroundColor(.havenPurple)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                    .font(.appBody)
                Text(statusText(center.status(id, account: account)))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Replay") {
                center.replay(id)
                onReplay(id)
            }
            .buttonStyle(.bordered)
            .tint(.havenPurple)
            .disabled(account.isEmpty)
            .accessibilityLabel(Text("Replay \(id.title)"))
        }
    }

    private func statusText(_ status: TutorialStatus) -> String {
        switch status {
        case .notStarted: return "Not seen yet"
        case .skipped: return "Skipped"
        case .done: return "Done"
        }
    }
}
