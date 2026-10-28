import SwiftUI

/// Media Servers › Suggested: known-good Blossom servers the user hasn't added
/// yet, each with an Add button. Hidden once every one is in the list.
/// Android twin: `SuggestedMediaServersSection.kt`.
struct SuggestedMediaServersSection: View {
    /// The user's current servers; suggestions already among them are hidden.
    let servers: [String]
    let onAdd: (String) -> Void

    var body: some View {
        let suggestions = SuggestedMediaServers.notYetAdded(servers)
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { server in
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.appSystem(size: 14))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.host)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                            Text(server.note)
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Add") { onAdd(server.url) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add \(server.host)")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Suggested")
            } footer: {
                Text("Servers other Nostr apps use. Prices and limits are set by each server and can change.")
            }
        }
    }
}
