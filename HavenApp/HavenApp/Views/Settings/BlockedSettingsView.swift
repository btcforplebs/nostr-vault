import SwiftUI

struct BlockedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    
    @State private var searchInput = ""
    @State private var isSearching = false
    /// Block Someone's choice: in the list's encrypted part instead of its
    /// public tags.
    @State private var blockPrivately = false
    /// Bumped when the mute list's private part is reopened, which the
    /// config doesn't publish.
    @State private var privateRevision = 0

    /// Public blocks (the mute list's `p` tags) and private ones (its
    /// encrypted part), as two lists.
    var sections: BlockedPeople.Sections {
        _ = privateRevision
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        // Same source as the dashboard's "N people blocked" count
        // (ConfigService.blockedHexPubkeys): the owner's legacy blacklist
        // counts until a per-account list exists, plus the private blocks.
        let listed = configService.config.blockedNpubsPerAccount[targetNpub]
            ?? (targetNpub == configService.config.ownerNpub ? configService.config.blacklistedNpubs : [])
        let privateNpubs = ProfileRepository.hexKeysToNpubs(
            MuteListStore.shared.privatePubkeys(forAccount: targetNpub).sorted())
        return BlockedPeople.sections(publicBlocks: listed, privateBlocks: privateNpubs) {
            Bech32.decode($0)?.hexString.lowercased() ?? $0.lowercased()
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("npub1...", text: $searchInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Block") {
                        if let npub = NpubValidation.typedNpub(searchInput) {
                            if blockPrivately {
                                configService.blockPrivately(npub)
                            } else {
                                configService.blockProfile(npub)
                            }
                            searchInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(NpubValidation.typedNpub(searchInput) == nil)
                }
                Toggle("Block privately", isOn: $blockPrivately)
            } header: {
                Text("Block Someone").settingInfo(.accountBlocked)
            } footer: {
                Text(blockPrivately
                     ? "Only you will see this block. It is encrypted in your block list and shows once your relays have it."
                     : "Anyone can see this block in your block list.")
            }

            let lists = sections
            Section {
                blockedRows(lists.publicBlocks, empty: "No public blocks.")
            } header: {
                Text("Public")
            } footer: {
                Text("Anyone can see these in your block list.")
            }

            Section {
                blockedRows(lists.privateBlocks, empty: "No private blocks.")
            } header: {
                Text("Private")
            } footer: {
                Text("Only you can see these. They are encrypted in your block list.")
            }

            MutedWordsSettingsView()

            CleanModeSettingsView()
        }
        .warmFormBackground()
        .groupedFormStyleCompat()
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in
            privateRevision += 1
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func blockedRows(_ npubs: [String], empty: String) -> some View {
        if npubs.isEmpty {
            Text(empty).foregroundColor(.secondary)
        } else {
            ForEach(npubs, id: \.self) { npub in
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
