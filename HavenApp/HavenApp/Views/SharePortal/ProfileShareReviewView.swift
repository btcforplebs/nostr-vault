import SwiftUI

/// Review a profile someone shared, then Follow or Block them. Nothing is
/// signed until one of those is tapped, and Block asks once more. Twin:
/// ProfileShareReviewContent.kt.
struct ProfileShareReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @ObservedObject private var feed = FeedService.shared
    @ObservedObject private var nostr = NostrService.shared
    @State private var picked = 0
    @State private var confirmBlock = false
    @State private var message: String?

    private var people: [String] { ProfileShareHandler.people(in: intent) }
    private var person: String? { people.indices.contains(picked) ? people[picked] : people.first }
    private var activeNpub: String {
        PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
    }
    private var wanted: String? { intent.account }
    private var isOnDevice: Bool { wanted.map { config.allAccountNpubs.contains($0) } ?? true }
    private var isActive: Bool { wanted.map { $0 == activeNpub } ?? true }
    private var isSelf: Bool { person?.lowercased() == config.activeAccountHexPubkey.lowercased() }
    private var ready: Bool { person != nil && isOnDevice && isActive && config.activeAccountCanSign && !isSelf }
    private var following: Bool { person.map { feed.followedPubkeys.contains($0) } ?? false }

    var body: some View {
        Form {
            if let person {
                Section("Profile") {
                    if people.count > 1 {
                        Picker("Person", selection: $picked) {
                            ForEach(Array(people.enumerated()), id: \.offset) { i, hex in
                                Text(ProfileShareHandler.displayName(hex)).tag(i)
                            }
                        }
                    }
                    Text(ProfileShareHandler.displayName(person)).font(.headline)
                    if let about = nostr.profiles[person]?.about, !about.isEmpty {
                        Text(about).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if isSelf { Text("That's you.").font(.footnote).foregroundStyle(.secondary) }
                }
            } else {
                Section { Text("This share doesn't name a Nostr profile.").foregroundStyle(.secondary) }
            }
            accountSection
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if let person {
                Section {
                    Button(following ? "Following" : "Follow") { follow(person) }
                        .disabled(!ready || following)
                    Button(ProfileShareHandler.isBlocked(person) ? "Blocked" : "Block", role: .destructive) { confirmBlock = true }
                        .disabled(!ready || ProfileShareHandler.isBlocked(person))
                } footer: {
                    Text("Follow and Block change your follow list and your mute list, which other Nostr apps read too.")
                }
            }
        }
        .confirmationDialog("Block \(person.map(ProfileShareHandler.displayName) ?? "")?", isPresented: $confirmBlock,
                            titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let person, ProfileShareHandler.block(person) { close() }
            }
        } message: {
            Text("Their notes are hidden everywhere you use this account.")
        }
        .onAppear { nostr.fetchMissingProfiles(for: people) }
    }

    @ViewBuilder
    private var accountSection: some View {
        let npub = wanted ?? activeNpub
        let profile = Bech32.decode(npub).flatMap { nostr.profiles[$0.hexString] }
        let name = profile?.bestName ?? String(npub.prefix(16)) + "…"
        Section("As") {
            Text(name)
            if !isOnDevice {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if !isActive {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            } else if !config.activeAccountCanSign {
                Text("This account is read-only here.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func follow(_ hex: String) {
        message = nil
        switch ProfileShareHandler.follow(hex) {
        case .followed, .alreadyFollowing, .queued: close()
        case .failed(let why): message = why
        }
    }
}
