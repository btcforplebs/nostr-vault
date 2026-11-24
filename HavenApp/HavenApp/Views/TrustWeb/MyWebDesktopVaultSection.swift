#if os(iOS)
import SwiftUI

/// My Web › Desktop Vault: what the globe's outer rings are, off the globe
/// (Logen, 11/24: the status sat bottom-left over the web). With a rank,
/// "Found by your desktop Vault" and one chip per ring ("3 hops · top 300"),
/// each opening that ring (`OuterRingSheet`). A paired desktop Vault that
/// has not ranked yet says so. Pull asks the desktop Vault for its ranking
/// now: the same catch-up its new-rank nudge starts
/// (`MeshCopyV2Service.rankReady`). With no desktop Vault, the invite
/// (`HavenInviteCard`) until "Not now". Android twin:
/// `ui/components/trustweb/MyWebDesktopVaultSection.kt`.
struct MyWebDesktopVaultSection: View {
    /// A face in a ring's sheet: close My Web and show their card.
    let onPick: (String) -> Void
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var watch = TrustMapOuterWatch.shared
    @ObservedObject private var copies = MeshCopyV2Service.shared
    @AppStorage(TrustMapOuter.inviteHiddenKey) private var inviteHidden = false
    @State private var open: TrustMapOuter.Ring?

    private var desktop: MeshDevice? {
        DesktopVaultPick.desktop(FipsMeshDevices.current(configService.config), lastSync: copies.syncState.lastAt)
    }

    var body: some View {
        let outer = watch.outer
        Group {
            switch outer.source {
            case .ranked, .waiting:
                DashboardSection(title: "Desktop Vault") {
                    pullRow(outer)
                    if outer.source == .ranked, !outer.rings.isEmpty {
                        DashboardDivider()
                        ringChips(outer.rings)
                    }
                }
            case .invite where !inviteHidden:
                DashboardSection(title: "Desktop Vault", framed: false) {
                    HavenInviteCard(onNotNow: { inviteHidden = true })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                EmptyView()
            }
        }
        .sheet(item: $open) { ring in
            OuterRingSheet(ring: ring) { pick in
                open = nil
                onPick(pick)
            }
        }
        // A pull's catch-up rewrote the rank file: read it now, not at the
        // next trip to the background.
        .onChange(of: copies.syncState.running) { was, now in
            if let was, was == desktop?.npub, now == nil { DiscoveryReachStore.shared.refresh() }
        }
    }

    /// The status line and Pull.
    private func pullRow(_ outer: TrustMapOuter) -> some View {
        let peer = desktop?.npub
        let pulling = peer.map { copies.syncState.running == $0 || copies.syncState.queued.contains($0) } ?? false
        // Only a desktop this device copies from has a catch-up to run.
        let canPull = peer.map { copies.syncState.lastAt[$0] != nil } ?? false
        return DashboardRow(icon: "desktopcomputer", title: title(outer),
                            detail: detail(peer: peer, pulling: pulling, canPull: canPull),
                            state: .info) {
            RowButton(title: "Pull", isLoading: pulling) {
                if let peer { copies.rankReady([peer]) }
            }
            .disabled(pulling || !canPull)
            .accessibilityHint(Text("Asks your desktop Vault for its ranking now"))
        }
    }

    private func title(_ outer: TrustMapOuter) -> String {
        outer.source == .ranked ? TrustMapOuter.foundLabel : TrustMapOuter.waitingLabel
    }

    private func detail(peer: String?, pulling: Bool, canPull: Bool) -> String {
        if pulling { return "Pulling the ranking over the mesh…" }
        if peer != nil, !canPull { return "Copy your vault from it first, in Settings › Your Devices" }
        if let peer, copies.syncState.failed[peer] != nil { return "Couldn't reach it over the mesh. Try again" }
        guard let peer, let at = copies.syncState.lastAt[peer], at > 0 else {
            return "Read over the mesh"
        }
        return "Read over the mesh \(VaultStatusText.ago(Int64(at), now: Date()))"
    }

    private func ringChips(_ rings: [TrustMapOuter.Ring]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(rings) { ring in
                    Button { open = ring } label: {
                        Text(TrustMapOuter.chipText(ring))
                            .font(.appSystem(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.accentText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.havenPurple.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(ring.hop) hops out, top \(ring.count) people, found by your desktop Vault"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}
#endif
