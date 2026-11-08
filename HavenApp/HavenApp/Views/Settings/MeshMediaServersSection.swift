import SwiftUI

/// Media Servers › Your Vaults on the Mesh: the owner's desktop and mobile
/// vaults from My Devices, each with "Add to my media servers", and every
/// mesh entry already on their published list, with Remove. Linking a device
/// no longer lists it: this is the one place a vault goes on the media server
/// list (kind 10063) or comes off it (Logen via Tod, 2026-11-08). Add and
/// Remove only change the draft on screen; the page's Save publishes the
/// list once (`MediaServersDraft`).
struct MeshMediaServersSection: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostr = NostrService.shared
    @Binding var draft: MediaServersDraft

    private var listed: [String] { nostr.serverLists[nostr.activeHexPubkey] ?? [] }

    private var rows: [MeshMediaServerRow] {
        #if os(iOS)
        HomeVaultLogic.meshMediaServerRows(devices: FipsMeshDevices.current(configService.config), listed: listed,
                                           own: FipsMeshService.shared.ownMeshNpub, photoNpub: nil)
        #else
        HomeVaultLogic.meshMediaServerRows(devices: configService.config.meshDevices, listed: listed,
                                           own: MacFipsMeshService.shared.ownNpub, photoNpub: PhotoNode.npub())
        #endif
    }

    /// A list with only mesh entries is never published (NIP-F1), so Add
    /// waits for a public media server: one on the draft (it goes out with
    /// the same Save) or already on the published list.
    private var hasPublicServer: Bool {
        var config = configService.config
        config.blossomMirrors = draft.mirrors
        return (config.activeBlossomMirrors + listed).contains(where: HomeVaultLogic.isPublicServer)
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row($0) }
            } header: {
                Text("Your Vaults on the Mesh")
            } footer: {
                Text(hasPublicServer
                     ? "Listing a vault tells apps that speak the mesh (FIPS) where to load your media. Your media server list is public."
                     : "Add a media server above first. A list with only mesh vaults isn't published.")
            }
            .onChange(of: listed) { _, _ in draft.publishedListChanged() }
        }
    }

    private func row(_ row: MeshMediaServerRow) -> some View {
        let shownListed = draft.shownListed(row.entry, published: row.listed)
        return HStack(spacing: 12) {
            Image(systemName: row.role?.icon ?? "point.3.connected.trianglepath.dotted")
                .font(.appSystem(size: 14))
                .foregroundColor(.teal)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name ?? "Mesh vault")
                    .font(.appSubheadline)
                Text("\(row.role?.label ?? "Mesh vault") · \(row.npub.prefix(12))…\(row.npub.suffix(6))")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                if !row.removable {
                    Text("Listed while Mesh is on")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if shownListed {
                if row.removable {
                    Button("Remove", role: .destructive) { set(row, listed: false) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(row.name ?? "mesh vault") from my media servers")
                }
            } else {
                Button("Add to my media servers") { set(row, listed: true) }
                    .buttonStyle(.borderless)
                    .disabled(!hasPublicServer)
            }
        }
        .padding(.vertical, 2)
    }

    private func set(_ row: MeshMediaServerRow, listed: Bool) {
        draft.setMesh(row.entry, listed: listed, published: row.listed)
    }
}
