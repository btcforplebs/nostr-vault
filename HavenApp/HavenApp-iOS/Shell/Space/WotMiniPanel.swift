import SwiftUI

/// Web of Trust mini, the web's second Your space panel: how big your web is
/// and who is new in it (people your follows have come to vouch for since
/// this device last looked). A face opens them in WoT, picked out on your
/// globe, as a profile's Open in WoT does. The web's panel also draws a
/// small turning globe; the iPad leaves it to the WoT tab.
struct WotMiniPanel: View {
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var nostrService = NostrService.shared
    @EnvironmentObject var configService: ConfigService
    @State private var fresh: [String] = []
    @State private var askedForWeb = false

    private var me: String { configService.activeAccountHexPubkey.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sizeLine)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
            if feedService.followedPubkeys.isEmpty {
                EmptyView()
            } else if fresh.isEmpty {
                Text(feedService.extendedNetworkPubkeys.isEmpty
                     ? (feedService.isLoadingExtendedNetwork ? "Loading your web..." : "Your follows' lists haven't come in yet")
                     : "No one new in your web this week")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            } else {
                Text("New in your web")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(fresh.prefix(WotNewcomers.faces), id: \.self) { pk in
                        Button { WOTOpenRequest.shared.open(pk) } label: {
                            AvatarView(url: nostrService.profiles[pk]?.pictureURL, pubkey: pk, size: 34)
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
            Button { WOTOpenRequest.shared.open(me) } label: {
                Label("Open my web", systemImage: TrustMap.Layer.everyone.symbolName)
                    .font(.appSystem(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.havenPurple)
            .disabled(me.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .onChange(of: feedService.extendedNetworkPubkeys, initial: true) { _, vouched in update(vouched) }
        .onChange(of: me) { _, _ in update(feedService.extendedNetworkPubkeys) }
        .onAppear(perform: askForWebIfMissing)
    }

    private var sizeLine: String {
        let follows = feedService.followedPubkeys.count
        guard follows > 0 else { return "Follow people to build your web" }
        let web = feedService.extendedNetworkPubkeys.count
        let followText = "\(follows.formatted()) \(follows == 1 ? "follow" : "follows")"
        // The ranked web keeps its top 500 (ContactManager.rankExtendedNetwork): at the cap there are more.
        let webText = web >= 500 ? "\(web.formatted())+" : web.formatted()
        return web > 0 ? "\(followText) · \(webText) in your web" : followText
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
