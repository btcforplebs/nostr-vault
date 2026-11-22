import SwiftUI

/// Settings › Feeds › Discovery reach: the slider over the desktop Vault's
/// trust rank (`DiscoveryReach`). With no rank file it only says how to get
/// one. Android twin: `ui/screens/settings/DiscoveryReachSettingsSection.kt`.
struct DiscoveryReachSettingsSection: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var store = DiscoveryReachStore.shared
    /// The bar while the slider is held; saved when it is let go, so the
    /// feed is rebuilt once, not on every step.
    @State private var dragging: Double?

    var body: some View {
        Section {
            if let copy = store.copy {
                let bar = dragging ?? DiscoveryReach.bar(saved: configService.config.discoveryBar, copy: copy)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Score")
                        Spacer()
                        Text("\(Int(bar)) and up")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: { bar }, set: { dragging = $0 }),
                           in: DiscoveryReach.range(copy), step: 1) { editing in
                        guard !editing, let value = dragging else { return }
                        configService.config.discoveryBar = DiscoveryReach.saved(value, copy: copy)
                        dragging = nil
                    }
                    Text(DiscoveryReach.countText(DiscoveryReach.count(copy, bar: bar)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Scores come from Nostr Vault on your desktop. Once it has ranked your network, this device gets the scores from it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Discovery Reach")
        } footer: {
            if let copy = store.copy {
                Text("Underrated and Discover also show people your desktop Vault ranked at this score or higher. Lower lets more in. Ranked \(Date(timeIntervalSince1970: TimeInterval(copy.builtAt)).formatted(.relative(presentation: .named))).")
            }
        }
        .onAppear { store.refresh() }
    }
}
