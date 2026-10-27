import SwiftUI

#if os(iOS)
/// iOS-only settings page for the always-on Mac Nostr Vault relay.
/// A single https:// URL entry derives the WSS address for sync and optionally
/// populates Import relays, Blastr relays, and Blossom mirrors automatically.
struct MacRelaySettingsView: View {
    @EnvironmentObject var configService: ConfigService

    /// Track computed URLs from the previous save so we can migrate array entries on URL change.
    @State private var prevWssURL: String = ""
    @State private var prevHttpsURL: String = ""

    var body: some View {
        Form {
            // ── URL Input ──────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    CommitOnEndTextField("https://relay.example.com or npub1…", text: $configService.config.macRelayURL)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color.platformControlBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your Mac's Address").settingInfo(.relaySync)
            }

            // ── Derived Addresses ──────────────────────────────────────
            let wssURL = configService.config.macRelayWssURL
            let httpsURL = configService.config.macRelayHttpsURL

            if !wssURL.isEmpty {
                Section {
                    // Always-on: Feed Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Feed Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Import Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Blastr Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blastr Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Blossom Mirror
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blossom Mirror")
                                .font(.appSubheadline.bold())
                            Text(httpsURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Also Used For")
                }
            }

            if !wssURL.isEmpty || configService.config.macRelayMeshNpub != nil {
                // ── Sync ───────────────────────────────────────────────
                Section {
                    MacRelaySyncStatusView()
                } header: {
                    Text("Sync")
                }
            }
        }
        .groupedFormStyleCompat()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prevWssURL = configService.config.macRelayWssURL
            prevHttpsURL = configService.config.macRelayHttpsURL
        }
        .onChange(of: configService.config.macRelayURL) { _, _ in
            migrateRelayURLs()
        }
    }

    // MARK: - URL change migration

    /// When the Mac relay URL changes, update any array entries that were derived from the old URL
    /// so Feed relays, Import relays, Blastr relays, and Blossom Mirrors stay in sync automatically.
    private func migrateRelayURLs() {
        let newWss = configService.config.macRelayWssURL
        let newHttps = configService.config.macRelayHttpsURL

        if !prevWssURL.isEmpty && prevWssURL != newWss {
            configService.config.feedRelays = configService.config.feedRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
            configService.config.importSeedRelays = configService.config.importSeedRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
            configService.config.blastrRelays = configService.config.blastrRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
        }

        if !prevHttpsURL.isEmpty && prevHttpsURL != newHttps {
            configService.config.blossomMirrors = configService.config.blossomMirrors
                .map { $0 == prevHttpsURL ? newHttps : $0 }
                .filter { !$0.isEmpty }
        }

        // The DM inbox list leads with the Mac relay's inbox. Drop the old
        // address (another device may have copied it into dmRelays when it
        // adopted the published list) and publish, so senders and every
        // device move to the new one.
        if prevWssURL != newWss {
            if !prevWssURL.isEmpty {
                let oldInbox = HavenConfig.normalizedRelayURL(prevWssURL + "/inbox").lowercased()
                configService.config.dmRelays.removeAll { HavenConfig.normalizedRelayURL($0).lowercased() == oldInbox }
            }
            NostrService.shared.publishOwnerDMInboxList()
        }

        prevWssURL = newWss
        prevHttpsURL = newHttps
    }
}
#endif
