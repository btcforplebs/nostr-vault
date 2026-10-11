import AVKit
import Combine
import SwiftUI

/// The Music feed's top-right controls: Trending (this week or month),
/// an artist picker, and Wavlake artists you follow on Nostr.
struct MusicToolbarButtons: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        HStack(spacing: 4) {
            toolbarMenu(icon: isTrending ? "flame.fill" : "flame", label: "Trending", isSelected: isTrending) {
                MusicTrendingMenuItems()
            }
            toolbarMenu(icon: artist != nil ? "person.crop.circle.fill" : "person.crop.circle",
                        label: artist.map { "Artist: \($0.name)" } ?? "Artists", isSelected: artist != nil) {
                MusicArtistMenuItems()
            }
            IconFilterButton(icon: isFollowing ? "person.2.fill" : "person.2", tooltip: "Artists you follow",
                             isSelected: isFollowing, color: .havenPurple) {
                feed.scope = .following
            }
            #if os(macOS)
            .help("Wavlake artists you follow on Nostr")
            #endif
        }
    }

    private var isTrending: Bool { feed.scope == .trending }
    private var isFollowing: Bool { feed.scope == .following }
    private var artist: WavlakeArtist? { feed.currentArtist }

    private func toolbarMenu<Items: View>(icon: String, label: String, isSelected: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: icon)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(isSelected ? .havenPurple : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .animation(Motion.toggle, value: isSelected)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(label)
        #endif
        .accessibilityLabel(label)
    }
}

/// This week / This month, for the toolbar's Trending menu and the
/// compact toolbar's single menu.
struct MusicTrendingMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        ForEach(MusicFeedState.TrendingWindow.allCases, id: \.self) { window in
            Button { feed.showTrending(window) } label: {
                Label("Trending \(window.title.lowercased())",
                      systemImage: feed.scope == .trending && feed.trendingWindow == window ? "checkmark" : "flame")
            }
        }
    }
}

/// Artists you've played or opened, newest first.
struct MusicArtistMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        if feed.recentArtists.isEmpty {
            Text("Artists you play or open show up here")
        } else {
            ForEach(feed.recentArtists) { artist in
                Button { feed.show(artist) } label: {
                    Label(artist.name, systemImage: feed.currentArtist?.id == artist.id ? "checkmark" : "person.crop.circle")
                }
            }
            Divider()
            Button(role: .destructive) { feed.clearRecentArtists() } label: {
                Label("Clear artists", systemImage: "trash")
            }
        }
    }
}

/// Everything in MusicToolbarButtons, as items for the compact toolbar menu.
struct MusicToolbarMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        MusicTrendingMenuItems()
        Button { feed.scope = .following } label: {
            Label("Artists you follow", systemImage: feed.scope == .following ? "checkmark" : "person.2")
        }
        Menu {
            MusicArtistMenuItems()
        } label: {
            Label("Artists", systemImage: "person.crop.circle")
        }
    }
}
