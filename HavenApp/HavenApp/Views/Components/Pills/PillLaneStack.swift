import SwiftUI

/// Every pill in the lane, most important kind on top (see `docs/pills.md`).
/// The Mac draws this over the main window and over a sheet; iPhone and
/// iPad draw the same list in `AppBannerStack`, in a window of their own,
/// where each banner also reports where it is for taps.
struct PillLaneStack: View {
    var body: some View {
        VStack(spacing: 0) {
            ErrorNotificationBanner()
            PostActionNotificationBanner()
            ZapNotificationBanner()
            FollowNotificationBanner()
            MediaUploadNotificationBanner()
            RelayActivityBanner()
            ActionToastBanner()
            FilterNoteBanner()
        }
        .padding(.top, PillStyle.gap)
    }
}
