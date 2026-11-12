import SwiftUI

/// Web of Trust mini, the web's second Your space panel: how big your web is
/// and who is new in it (`WotNewcomersView`: people your follows have come
/// to vouch for since this device last looked). A face opens them in WoT,
/// picked out on your globe, as a profile's Open in WoT does. The web's panel also draws a
/// small turning globe; the iPad leaves it to the WoT tab.
struct WotMiniPanel: View {
    @ObservedObject private var feedService = FeedService.shared
    @EnvironmentObject var configService: ConfigService

    private var me: String { configService.activeAccountHexPubkey.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sizeLine)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
            WotNewcomersView(me: me) { WOTOpenRequest.shared.open($0) }
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
}
