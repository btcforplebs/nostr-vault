import SwiftUI

/// The WOT tab: the Web of Trust globe with nobody picked. You sit at the
/// core with your follows around you and the rest of your web as the haze.
/// Tapping a face centres on them and shows how they reach you, the same
/// globe a post's WOT button opens, pointed back at you.
struct WOTTabView: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    private var me: String { configService.activeAccountHexPubkey }

    var body: some View {
        NavigationStack {
            TrustWebView(author: me, path: Self.startingPath(me), isWOTTab: true)
                // Cards and pills sit above the floating tab bar; the globe
                // itself runs under it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: tabBarHeight)
                }
        }
        // This tab stays alive: a new account draws a new globe. The globe
        // itself keeps up with your follow list.
        .id(me)
    }

    /// The path from you to you: no bridges, nothing to look up.
    static func startingPath(_ me: String) -> TrustPath {
        TrustPath.resolve(author: me, me: me, follows: [], trustGraph: [], contactLists: [])
    }
}
