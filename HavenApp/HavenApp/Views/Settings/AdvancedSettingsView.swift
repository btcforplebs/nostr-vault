import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Engine")
                        .settingInfo(.advDatabase)
                    Spacer()
                    Text(configService.config.dbEngine == "badger" ? "BadgerDB" : "LMDB")
                        .foregroundColor(.secondary)
                }

                #if os(macOS)
                HStack {
                    Text("Media Folder")
                    Spacer()
                    Text(configService.config.blossomPath)
                        .foregroundColor(.secondary)

                    Button {
                        let fullPath = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath).path
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
                #endif
            } header: {
                Text("Database")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Factory Reset", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .settingInfo(.advFactoryReset)
            } header: {
                Text("Danger Zone")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Are you sure?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Everything", role: .destructive) {
                relayManager.stopRelay {
                    Task { @MainActor in
                        configService.resetApp()
                        #if canImport(AppKit)
                        ConfigService.quitApp()
                        #endif
                    }
                }
            }
        } message: {
            Text(resetConsequence)
        }
    }

    /// Says outright that the private key goes, not just relay data: the key
    /// lives in config.json, which the reset deletes.
    private var resetConsequence: String {
        let npub = configService.config.ownerNpub
        let key = npub.isEmpty ? "the private key stored on this device" : "the private key for \(npub.prefix(12))… stored on this device"
        #if canImport(AppKit)
        let after = "The app will then quit."
        #else
        let after = "The app then starts over at setup."
        #endif
        return "This deletes \(key), and the keys of any other accounts here, along with all relay data and saved passwords. If you have no backup of your key elsewhere, it cannot be recovered. \(after)"
    }
}
