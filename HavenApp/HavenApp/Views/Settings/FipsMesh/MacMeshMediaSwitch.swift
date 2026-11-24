import SwiftUI

#if os(macOS)
/// FIPS Mesh › Share With Others › "Media over the Mesh" (Desktop Vaults P8,
/// §2.3): this Mac's own mesh address in the owner's media servers (10063).
/// Beta and off by default (Logen 13:42Z). It replaces the photo node the Mac
/// used to list on its own whenever Mesh was on.
///
/// Like a phone's Vault switch (DesktopVaultListedSection), it reads the
/// newest published list each time and each tap changes only this Mac's
/// entry in it (DesktopVaultListEdit, rule 7). An entry an older build
/// listed reads as on until it is turned off (§3 step 4). Turning on needs
/// the engine running, or the entry would point at a node nobody can reach;
/// turning off is always allowed.
struct MacMeshMediaSwitch: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var mesh = MacFipsMeshService.shared
    /// nil: not loaded yet, or the relays couldn't say.
    @State private var listed: Bool?
    @State private var loading = true
    @State private var busy = false
    @State private var line: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { listed ?? false }, set: set)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Media over the Mesh").font(.appBody)
                        Text("Beta")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple.opacity(0.15), in: Capsule())
                            .foregroundColor(.accentText)
                    }
                    Text("Lists this Mac's mesh address in your media servers, after the web ones. Apps that speak the mesh can load your media from it, and Auto-Mirror copies there over the mesh.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.havenPurple)
            .disabled(listed == nil || busy || (listed == false && !canTurnOn))
            if let shown = caption {
                Text(shown)
                    .font(.appCaption)
                    .foregroundColor(line == nil ? .secondary : .orange)
            }
            Link("What is this? (NIP-F1)", destination: DesktopVaultText.nipF1URL)
                .font(.appCaption)
        }
        .task(id: mesh.ownNpub) { await load() }
    }

    private var canTurnOn: Bool { mesh.running && mesh.ownNpub != nil }

    private var caption: String? {
        if let line { return line }
        if loading { return "Loading your media servers…" }
        if listed == nil { return DesktopVaultListEdit.notLoadedMessage }
        if listed == false && !canTurnOn { return "Turn on Mesh with a device added first: the mesh must be running to answer." }
        return nil
    }

    private var thisMac: DesktopVault {
        configService.config.thisMacVault(meshNpub: mesh.ownNpub, name: Host.current().localizedName ?? "This Mac")
    }

    private func load() async {
        loading = true
        let tags = await DesktopVaultListEdit.current(.media)
        listed = tags.map { DesktopVaultsLists.isListed(thisMac, path: .mesh, in: .media, tags: $0) }
        loading = false
    }

    private func set(_ on: Bool) {
        guard mesh.ownNpub != nil else { return }
        let vault = thisMac
        busy = true
        line = nil
        DesktopVaultListEdit.set(on, vault: vault, path: .mesh, list: .media,
                                 vaults: configService.config.vaultsWithThisMac(vault)) { outcome in
            busy = false
            if let message = outcome.message {
                line = message
                return
            }
            // Show the change now; the relays echo it back later.
            listed = on
        }
    }
}
#endif
