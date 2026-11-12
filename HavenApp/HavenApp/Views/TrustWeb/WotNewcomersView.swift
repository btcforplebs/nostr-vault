import SwiftUI

/// Who is new in your web, as faces: people your follows have come to vouch
/// for since this device last looked (`WotNewcomers`). Your space's WoT mini
/// panel on the iPad shows it, and so does My Web. A face is handed to
/// `onOpen`.
struct WotNewcomersView: View {
    /// The account whose web this is; its seen list is kept under it.
    let me: String
    /// The "New in your web" line over the faces. My Web's section title says it already.
    var showsTitle = true
    var faceSize: CGFloat = 34
    let onOpen: (String) -> Void

    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var nostrService = NostrService.shared
    @State private var fresh: [String] = []
    @State private var askedForWeb = false

    var body: some View {
        Group {
            if feedService.followedPubkeys.isEmpty {
                EmptyView()
            } else if fresh.isEmpty {
                Text(feedService.extendedNetworkPubkeys.isEmpty
                     ? (feedService.isLoadingExtendedNetwork ? "Loading your web..." : "Your follows' lists haven't come in yet")
                     : "No one new in your web this week")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if showsTitle {
                        Text("New in your web")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(fresh.prefix(WotNewcomers.faces), id: \.self) { pk in
                            Button { onOpen(pk) } label: {
                                AvatarView(url: nostrService.profiles[pk]?.pictureURL, pubkey: pk, size: faceSize)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(nostrService.profiles[pk]?.bestName ?? "them") in WoT")
                        }
                        if fresh.count > WotNewcomers.faces {
                            Text("+\(fresh.count - WotNewcomers.faces)")
                                .font(.appSystem(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: feedService.extendedNetworkPubkeys, initial: true) { _, vouched in update(vouched) }
        .onChange(of: me) { _, _ in update(feedService.extendedNetworkPubkeys) }
        .onAppear(perform: askForWebIfMissing)
    }

    /// The web is worked out for the Discover feed; until that has run once
    /// (it is cached), ask for it here.
    private func askForWebIfMissing() {
        guard !askedForWeb, feedService.extendedNetworkPubkeys.isEmpty, !feedService.followedPubkeys.isEmpty,
              !feedService.isLoadingExtendedNetwork else { return }
        askedForWeb = true
        feedService.loadExtendedNetwork {}
    }

    private func update(_ vouched: [String]) {
        guard !me.isEmpty, !vouched.isEmpty else { fresh = []; return }
        let key = WotNewcomers.key(me)
        let kept = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WotNewcomers.self, from: $0) }
        let next = WotNewcomers.update(vouched: vouched, kept: kept, now: Int64(Date().timeIntervalSince1970))
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: key) }
        fresh = next.fresh.map(\.pubkey)
        nostrService.fetchMissingProfiles(for: Array(fresh.prefix(WotNewcomers.faces)))
    }
}
