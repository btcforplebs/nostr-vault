import SwiftUI

struct BlockedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    
    @State private var searchInput = ""
    @State private var isSearching = false
    
    var blockedNpubs: [String] {
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        return configService.config.blockedNpubsPerAccount[targetNpub] ?? []
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
