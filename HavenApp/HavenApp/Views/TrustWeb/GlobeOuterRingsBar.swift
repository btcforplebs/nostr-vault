import SwiftUI

/// Under your own globe on the WOT tab: what the outer rings are. With a
/// rank, "Found by your desktop Vault" and one chip per ring, each opening
/// that ring as a community (`OuterRingSheet`). A paired desktop Vault
/// that has not ranked yet says so. With no desktop Vault, the invite
/// (`HavenInviteCard`) until "Not now". Android twin:
/// `ui/components/trustweb/GlobeOuterRingsBar.kt`.
struct GlobeOuterRingsBar: View {
    /// Opens a person from a ring's sheet.
    let onPick: (String) -> Void
    @ObservedObject private var watch = TrustMapOuterWatch.shared
    @AppStorage(TrustMapOuter.inviteHiddenKey) private var inviteHidden = false
    @State private var open: TrustMapOuter.Ring?

    var body: some View {
        let outer = watch.outer
        Group {
            switch outer.source {
            case .ranked where !outer.rings.isEmpty:
                VStack(alignment: .leading, spacing: 6) {
                    Text(TrustMapOuter.foundLabel)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(outer.rings) { ring in
                                Button { open = ring } label: {
                                    Text(TrustMapOuter.chipText(ring))
                                        .font(.appSystem(size: 13, weight: .semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(.ultraThinMaterial))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("\(ring.hop) hops out, \(ring.count) people, found by your desktop Vault"))
                            }
                        }
                    }
                }
            case .waiting:
                Text(TrustMapOuter.waitingLabel)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
            case .invite where !inviteHidden:
                HavenInviteCard(onNotNow: { inviteHidden = true })
            default:
                EmptyView()
            }
        }
        .environment(\.colorScheme, .dark)
        .sheet(item: $open) { ring in
            OuterRingSheet(ring: ring, bar: outer.bar) { pick in
                open = nil
                onPick(pick)
            }
        }
    }
}
