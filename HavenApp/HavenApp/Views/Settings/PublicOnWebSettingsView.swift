import SwiftUI

#if os(macOS)
/// Your Vault › Public on the web (the Mac): the advanced last step. Off, the
/// vault is reached by your own devices over the mesh and listed nowhere by
/// its web address. On, its domain goes in your relay list (10002), your DM
/// inbox (10050) and the relay hints in your posts, and the domain, port and
/// tunnel settings show. The switch only lists or unlists the domain: a
/// tunnel you run keeps serving until you stop it. The fipsmesh entry is
/// separate, under Media Servers › Your Vaults (Logen 2026-11-12).
struct PublicOnWebSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    /// Never touched: on when a domain is already set, so nothing an owner
    /// published before this switch existed is dropped.
    private var isOn: Bool { configService.config.publicOnWeb ?? !configService.config.isLocal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { isOn }, set: set)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make this vault public on the web").font(.appBody)
                            Text(isOn ? statusLine : "Off: your devices reach it over the mesh")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(Color.havenPurple)
                } footer: {
                    Text("Needs your own domain and a tunnel. On: your domain goes in your relay list and DM inbox, so other apps can reach this vault. Turning it off takes it out of your DM inbox now and out of your relay list the next time you save Relays. A tunnel you started keeps running until you stop it.")
                }
            }
            .groupedFormStyleCompat()
            if isOn {
                MacRelayDomainSettingsView()
            }
        }
    }

    private var statusLine: String {
        configService.config.listsOwnDomain ? "Listed as wss://\(configService.config.sanitizedRelayURL)" : "Add your domain below"
    }

    private func set(_ on: Bool) {
        let oldInbox = configService.config.ownHavenDMInboxURL
        configService.config.publicOnWeb = on
        let newInbox = configService.config.ownHavenDMInboxURL
        if oldInbox != newInbox {
            NostrService.shared.publishOwnerDMInboxMove(from: oldInbox, to: newInbox)
        }
    }
}
#endif
