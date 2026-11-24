import SwiftUI

#if os(macOS)
/// Your Vault › Public on the web (the Mac): the advanced last step. Off, the
/// vault is reached by your own devices over the mesh and listed nowhere by
/// its web address. On, its domain goes in your relay list (10002), your DM
/// inbox (10050) and the relay hints in your posts, and the domain, port and
/// tunnel settings show. The switch only lists or unlists the domain: a
/// tunnel you run keeps serving until you stop it. The mesh entry is
/// separate: "Media over the Mesh" on the Mesh page (MacMeshMediaSwitch).
///
/// Each tap edits the newest published lists through DesktopVaultListEdit,
/// with this Mac as a Vault (Desktop Vaults P8, §2.5): only this Mac's
/// entries change. Any number of Macs may be public at once (rule 3), so
/// nothing asks to "move" public web and no Mac turns itself off.
struct PublicOnWebSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    /// Why a list change didn't go out (unusable list, unsettled lookup).
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
                    Text("Needs your own domain and a tunnel. On: your domain goes in your relay list and DM inbox now, after your other Vaults, so other apps can reach this vault. Your other Macs can be public too. Turning it off takes it out of both now. A tunnel you started keeps running until you stop it.")
                }
            }
            .warmFormBackground()
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
        let wasOn = isOn
        configService.config.publicOnWeb = on
        guard on != wasOn else { return }
        let config = configService.config
        let thisMac = config.thisMacVault(meshNpub: MacFipsMeshService.shared.ownNpub,
                                          name: Host.current().localizedName ?? "This Mac")
        // No reachable domain yet: nothing is listed; adding one below lists it.
        guard let https = thisMac.httpsURL else { return }
        if on, DesktopVaultsEditing.isIPHost(https) {
            notice = DesktopVaultsEditing.ipHostMessage
            return
        }
        // Relays, then the DM inbox, each from the newest list (rule 7).
        let vaults = config.vaultsWithThisMac(thisMac)
        // A line per list that didn't change; the switch stays where it was
        // set, so another tap (or a Relays save) can finish the job.
        DesktopVaultListEdit.set(on, vault: thisMac, path: .web, list: .relays, vaults: vaults) { first in
            DesktopVaultListEdit.set(on, vault: thisMac, path: .web, list: .inbox, vaults: vaults) { second in
                var lines: [String] = []
                for line in [first.message, second.message].compactMap({ $0 }) where !lines.contains(line) {
                    lines.append(line)
                }
                notice = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
        }
    }
}
#endif
