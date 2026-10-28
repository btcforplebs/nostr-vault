import SwiftUI

/// Under the attachments: where they will be uploaded, and the way to the
/// media server settings to change that. Twin of Android's `UploadServersLink`.
struct UploadServersLink: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showMediaServers = false

    var body: some View {
        let servers = configService.config.activeBlossomMirrors
        Button {
            showMediaServers = true
        } label: {
            HStack(spacing: 0) {
                Text(ServerListAdoption.summary(servers))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(servers.isEmpty ? "  Add a server" : "  Media servers")
                    .fontWeight(.semibold)
                    .foregroundColor(.havenPurple)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.appSystem(size: 13))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens media servers")
        .padding(.horizontal, 16)
        .sheet(isPresented: $showMediaServers) {
            NavigationStack {
                BlossomSettingsView()
                    .settingsPage("Media Servers")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMediaServers = false }
                        }
                    }
            }
            .environmentObject(configService)
            .environmentObject(relayManager)
        }
    }
}
