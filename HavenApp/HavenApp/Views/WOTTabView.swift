import SwiftUI

/// The WOT tab: the Web of Trust globe with nobody picked. You sit at the
/// core with your follows around you and the rest of your web as the haze.
/// Tapping a face centres on them and shows how they reach you, the same
/// globe a post's WOT button opens, pointed back at you.
struct WOTTabView: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    /// Only the follow count, not FeedService itself: the feed publishes on
    /// every note, and each would redraw the globe.
    @State private var followCount = FeedService.shared.followedPubkeys.count

    private var me: String { configService.activeAccountHexPubkey }

    var body: some View {
        NavigationStack {
            TrustWebView(author: me, path: Self.startingPath(me))
                // The footer's words sit above the floating tab bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: tabBarHeight)
                }
        }
        // The globe reads your follows once, when it appears, and this tab
        // stays alive: a new account, or a follow list that loaded or changed
        // since, draws a new globe.
        .id("\(me).\(followCount)")
        .onReceive(FeedService.shared.$followedPubkeys.map(\.count).removeDuplicates()) { followCount = $0 }
    }

    /// The path from you to you: no bridges, nothing to look up.
    static func startingPath(_ me: String) -> TrustPath {
        TrustPath.resolve(author: me, me: me, follows: [], trustGraph: [], contactLists: [])
    }
}
