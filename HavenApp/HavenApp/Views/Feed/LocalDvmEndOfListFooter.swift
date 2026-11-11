import SwiftUI

/// The end of a Popular, Catch Up or Underrated list. These feeds are a fixed
/// set the local DVM computed, so the list stops; without this it ran out onto
/// the background and read as broken (Logen 2026-11-11). Says the list is done
/// and how to get a new one.
struct LocalDvmEndOfListFooter: View {
    let feed: LocalDvmFeed
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 3)
            #if os(iOS)
            Text(feed.endOfListStatus + " Pull to refresh")
                .multilineTextAlignment(.center)
            #else
            Text(feed.endOfListStatus)
                .multilineTextAlignment(.center)
            Button("Refresh", action: onRefresh)
                .buttonStyle(.link)
            #endif
        }
        .font(.appSystem(size: 13))
        .foregroundColor(.secondary)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.endOfList")
    }
}
