import SwiftUI

/// One outer ring opened as a community: its best-ranked people, as your
/// desktop Vault scored them. Tapping someone opens them on the globe.
/// Android twin: `ui/components/trustweb/OuterRingSheet.kt`.
struct OuterRingSheet: View {
    let ring: TrustMapOuter.Ring
    let bar: Double?
    let onPick: (String) -> Void
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reach = DiscoveryReachStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ring.top, id: \.self) { key in
                        Button { onPick(key) } label: { row(key) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(TrustMapOuter.foundLabel). \(TrustMapOuter.countText(ring, bar: bar))")
                        .textCase(nil)
                } footer: {
                    if ring.count > ring.top.count {
                        Text("Showing the top \(ring.top.count.formatted()).")
                    }
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
            if let score = reach.copy?[key]?.score {
                Text("\(Int(score.rounded()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text("Score \(Int(score.rounded()))"))
            }
        }
        .contentShape(Rectangle())
    }
}
