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
    /// Why a list change on switch-off didn't go out (empty list, unsettled lookup).
    @State private var notice: String?

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
                    if let notice {
                        Text(notice)
                            .font(.appCaption)
                            .foregroundColor(.orange)
                    }
                } footer: {
                    Text("Needs your own domain and a tunnel. On: your domain goes in your relay list and DM inbox, so other apps can reach this vault. Turning it off takes it out of your relay list and DM inbox now. A tunnel you started keeps running until you stop it.")
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
        notice = nil
        let oldInbox = configService.config.ownHavenDMInboxURL
        let wasListed = configService.config.listsOwnDomain
        let domain = "wss://\(configService.config.sanitizedRelayURL)"
        configService.config.publicOnWeb = on
        let newInbox = configService.config.ownHavenDMInboxURL
        let show: @MainActor (String?) -> Void = { line in
            if let line { notice = [notice, line].compactMap { $0 }.joined(separator: "\n") }
        }
        // Off: the domain leaves the published 10002 now. Once it is no longer
        // pinned, Settings › Relays would read it back as one of the owner's
        // own rows and Save would keep it (Tron #1991).
        if wasListed && !configService.config.listsOwnDomain {
            NostrService.shared.publishOwnerRelayListDrop(domain, done: show)
        }
        if oldInbox != newInbox {
            NostrService.shared.publishOwnerDMInboxMove(from: oldInbox, to: newInbox, done: show)
        }
    }
}
#endif
