import SwiftUI

#if os(iOS)
/// A Vault's "Listed publicly" switches (Desktop Vaults P4, §2.3, §2.4):
/// relays (10002), DM inbox (10050) and media servers (10063) by its web
/// address, plus media over the Mesh (10063 `fipsmesh`), Beta and off by
/// default (Logen 13:42Z). There is no mesh relay switch yet (Logen 13:53Z).
/// Each switch reads the newest published list and each tap changes only this
/// Vault's entry in it (DesktopVaultListEdit, rule 7). A bare IP address is
/// never listed (rule 8). Android twin: inside `DesktopVaultDetailScreen.kt`.
struct DesktopVaultListedSection: View {
    let vault: DesktopVault
    @Binding var lists: [DesktopVaultList: [[String]]]
    let loading: Bool
    @EnvironmentObject var configService: ConfigService
    @State private var busy: Set<String> = []
    @State private var line: String?

    var body: some View {
        Section {
            if vault.httpsURL != nil {
                webSwitch(.relays, title: "Your relays", detail: "Others read your posts here")
                webSwitch(.inbox, title: "DM inbox", detail: "Others send you messages here")
                webSwitch(.media, title: "Media servers", detail: "Others load and upload your media here")
            }
            if vault.meshNpub != nil {
                meshMediaSwitch
            }
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading your lists…").font(.appCaption).foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Listed publicly")
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let line {
            Text(line).foregroundColor(.orange)
        } else if let https = vault.httpsURL, DesktopVaultsEditing.isIPHost(https) {
            Text(DesktopVaultsEditing.ipHostMessage + " It still syncs over this address.")
        } else if !loading, DesktopVaultList.allCases.contains(where: { lists[$0] == nil }) {
            Text(DesktopVaultListEdit.notLoadedMessage)
        } else if DesktopVaultList.allCases.contains(where: { list in
            lists[list].map { DesktopVaultsLists.overGuidance($0, list: list) } ?? false
        }) {
            Text(DesktopVaultsLists.overGuidanceNote)
        } else {
            Text("These lists are public. Turning a switch on puts this Vault after your other Vaults and before your own entries.")
        }
    }

    // MARK: Switches

    private func webSwitch(_ list: DesktopVaultList, title: String, detail: String) -> some View {
        let ipHost = vault.httpsURL.map(DesktopVaultsEditing.isIPHost) ?? true
        return Toggle(isOn: binding(.web, list)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.appCaption).foregroundColor(.secondary)
            }
        }
        .disabled(ipHost || lists[list] == nil || busy.contains(key(.web, list)))
    }

    private var meshMediaSwitch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding(.mesh, .media)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Media over the Mesh")
                        Text("Beta")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple.opacity(0.15), in: Capsule())
                            .foregroundColor(.accentText)
                    }
                    Text("Lists its mesh address on your media servers, after the web ones. Apps that speak the mesh can load your media from it, and Auto-Mirror copies there over the mesh.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(lists[.media] == nil || busy.contains(key(.mesh, .media)))
            Link("What is this? (NIP-F1)", destination: DesktopVaultText.nipF1URL)
                .font(.appCaption)
        }
    }

    private func key(_ path: DesktopVaultPath, _ list: DesktopVaultList) -> String { "\(path.rawValue)|\(list.rawValue)" }

    private func binding(_ path: DesktopVaultPath, _ list: DesktopVaultList) -> Binding<Bool> {
        Binding(
            get: { lists[list].map { DesktopVaultsLists.isListed(vault, path: path, in: list, tags: $0) } ?? false },
            set: { on in set(on, path: path, list: list) })
    }

    private func set(_ on: Bool, path: DesktopVaultPath, list: DesktopVaultList) {
        if on, path == .web, let https = vault.httpsURL, DesktopVaultsEditing.isIPHost(https) {
            line = DesktopVaultsEditing.ipHostMessage
            return
        }
        let k = key(path, list)
        busy.insert(k)
        line = nil
        DesktopVaultListEdit.set(on, vault: vault, path: path, list: list) { outcome in
            busy.remove(k)
            if let message = outcome.message {
                line = message
                return
            }
            // Show the change now; the relays echo it back later.
            if case .tags(let next) = DesktopVaultsLists.switching(on, vault, path: path, in: list, tags: lists[list],
                                                                   vaults: configService.config.desktopVaultsInEffect) {
                lists[list] = next
            }
        }
    }
}
#endif
