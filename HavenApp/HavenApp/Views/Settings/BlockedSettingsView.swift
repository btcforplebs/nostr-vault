import SwiftUI

struct BlockedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    
    @State private var searchInput = ""
    @State private var isSearching = false
    /// Bumped when the mute list's private part is reopened, which the
    /// config doesn't publish.
    @State private var privateRevision = 0

    var blockedNpubs: [String] {
        _ = privateRevision
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        // Same source as the dashboard's "N people blocked" count
        // (ConfigService.blockedHexPubkeys): the owner's legacy blacklist
        // counts until a per-account list exists, plus the private blocks.
        let listed = configService.config.blockedNpubsPerAccount[targetNpub]
            ?? (targetNpub == configService.config.ownerNpub ? configService.config.blacklistedNpubs : [])
        let listedHex = Set(listed.compactMap { Bech32.decode($0)?.hexString.lowercased() })
        let privateOnly = MuteListStore.shared.privatePubkeys(forAccount: targetNpub)
            .subtracting(listedHex).sorted()
        return listed + ProfileRepository.hexKeysToNpubs(privateOnly)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("npub1...", text: $searchInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Block") {
                        if searchInput.starts(with: "npub1") {
                            configService.blockProfile(searchInput.trimmingCharacters(in: .whitespacesAndNewlines))
                            searchInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!searchInput.starts(with: "npub1"))
                }
            } header: {
                Text("Block Someone").settingInfo(.accountBlocked)
            }

            Section("Blocked Accounts") {
                if blockedNpubs.isEmpty {
                    Text("No blocked accounts.").foregroundColor(.secondary)
                } else {
                    ForEach(blockedNpubs, id: \.self) { npub in
                        let hex = Bech32.decode(npub)?.hexString ?? ""
                        let profile = nostrService.profiles[hex]
                        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."

                        HStack {
                            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
                            VStack(alignment: .leading) {
                                Text(displayName).fontWeight(.semibold)
                                Text(npub).font(.appSystem(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Unblock") {
                                configService.unblockProfile(npub)
                            }.foregroundColor(.red)
                        }
                    }
                }
            }
        }
        .groupedFormStyleCompat()
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in
            privateRevision += 1
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
