import SwiftUI

/// What an empty Global feed shows. Global hides everyone outside your web of
/// trust, so a new account sees a page of strangers' notes filtered down to
/// nothing; without this the screen was black, with no spinner and no words.
struct GlobalFeedEmptyState: View {
    @ObservedObject var feedService: FeedService

    var body: some View {
        VStack(spacing: 14) {
            if feedService.isLoadingFeed || (feedService.globalAwaitsGraph && !feedService.waitsForFirstFollow) {
                ProgressView().tint(Color.havenPurple)
            } else {
                Image(systemName: "globe")
                    .font(.appSystem(size: 40, weight: .thin))
                    .foregroundColor(.havenPurple)
            }
            Text(message)
                .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }

    private var message: String {
        if feedService.isLoadingFeed { return "Loading feed…" }
        return feedService.emptyFeedStatus()
    }
}
