import SwiftUI

/// One outer ring opened as a community: its top people by score from the
/// globe list, whatever their score, as your desktop Vault scored them.
/// Tapping someone opens "why?" with how they connect; from there "Show on
/// the globe" opens them on the globe.
/// Android twin: `ui/components/trustweb/OuterRingSheet.kt`.
struct OuterRingSheet: View {
    let ring: TrustMapOuter.Ring
    let onPick: (String) -> Void
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var config = ConfigService.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reach = DiscoveryReachStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ring.top, id: \.self) { key in
                        NavigationLink {
                            TrustWhySheet(pubkey: key, me: config.activeAccountHexPubkey, copy: reach.copy) {
                                onPick(key)
                            }
                        } label: { row(key) }
                    }
                } header: {
                    Text("\(TrustMapOuter.foundLabel). \(TrustMapOuter.countText(ring))")
                        .textCase(nil)
                }
            }
            .navigationTitle("\(ring.hop) hops away")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .task { nostrService.fetchMissingProfiles(for: Array(ring.top.prefix(60))) }
    }

    private func row(_ key: String) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: nostrService.profiles[key]?.pictureURL, pubkey: key, size: 36)
            Text(nostrService.profiles[key]?.bestName ?? "npub…" + String(key.suffix(6)))
                .lineLimit(1)
            Spacer()
            if let score = reach.copy?.globePerson(key)?.score {
                Text("\(Int(score.rounded()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text("Score \(Int(score.rounded()))"))
            }
        }
        .contentShape(Rectangle())
    }
}
