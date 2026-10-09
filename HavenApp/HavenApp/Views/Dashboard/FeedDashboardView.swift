import SwiftUI

/// The feed dashboard: what your follows did in the last 24 hours. Activity
/// only; feed settings live in Settings > Feed.
struct FeedDashboardView: View {
    /// Opens a feed on Following and closes the dashboard.
    let onOpenFeed: (FeedMode) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var store = FeedDashboardStore.shared
    @ObservedObject private var nostr = NostrService.shared
    @ObservedObject private var feed = FeedService.shared
    @ObservedObject private var stats = StatsService.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingProfile: IdentifiableString?
    @State private var showingNote: IdentifiableString?
    @State private var showingTag: IdentifiableString?

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.followSetIsEmpty {
                        emptyState("Follow some people and their day shows up here.")
                    } else if let snapshot = store.snapshot {
                        content(snapshot)
                    } else {
                        loadingState
                    }
                }
                .padding(16)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .refreshable { store.refresh() }
            .navigationTitle("Dashboard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Dashboard").font(.appHeadline)
                        Text(store.isLoading ? "Updating…" : "Your network, last 24 hours")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear { store.loadIfNeeded() }
        .sheet(item: $showingProfile) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfile = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
        .sheet(item: $showingNote) { n in
            NoteDetailViewWrapper(noteId: n.id, onDismiss: { showingNote = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
        .sheet(item: $showingTag) { t in
            HashtagFeedView(tag: t.id)
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ s: FeedDashboardSnapshot) -> some View {
        statsGrid(s)
        if !s.live.isEmpty { liveCard(s.live) }
        if !s.mostActive.isEmpty { mostActiveCard(s.mostActive) }
        if !s.popular.isEmpty { popularCard(s.popular) }
        if !s.trending.isEmpty { trendingCard(s.trending) }
        if !s.tiles.isEmpty { tilesCard(s.tiles) }
        vaultRow
    }

    private func statsGrid(_ s: FeedDashboardSnapshot) -> some View {
        // Four across only where it fits; a phone gets 2×2 so nothing is cut off.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: isWide ? 4 : 2), spacing: 10) {
            statTile(value: s.posts, label: s.posts == 1 ? "post" : "posts", icon: "text.bubble", color: .blue) {
                onOpenFeed(.following)
            }
            statTile(value: s.activePeople, label: "people posted", icon: "person.2", color: .green) {
                onOpenFeed(.following)
            }
            statTile(value: s.satsReceived, label: "sats to you", icon: "bolt.fill", color: .orange) {
                openVault { NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil) }
            }
            statTile(value: s.newFollowers, label: s.newFollowers == 1 ? "new follower" : "new followers",
                     icon: "person.badge.plus", color: .purple, prefix: s.newFollowers > 0 ? "+" : "") {
                openVault { RelayFocus.request(type: "followers", eventId: "") }
            }
        }
    }

    private func statTile(value: Int, label: String, icon: String, color: Color, prefix: String = "",
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.appSubheadline)
                    .foregroundColor(color)
                Text(prefix + Self.compact(value))
                    .font(.appTitle2.monospacedDigit())
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func liveCard(_ streams: [LiveStream]) -> some View {
        card(title: "Live now", trailing: "\(streams.count)", icon: "dot.radiowaves.left.and.right",
             tint: .red, onMore: { onOpenFeed(.live) }) {
            VStack(spacing: 10) {
                ForEach(streams.prefix(3)) { stream in
                    Button { onOpenFeed(.live) } label: {
                        HStack(spacing: 10) {
                            AvatarView(url: nostr.profiles[stream.hostPubkey]?.pictureURL,
                                       pubkey: stream.hostPubkey, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stream.title ?? "Live stream")
                                    .font(.appSubheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(name(stream.hostPubkey))
                                    .font(.appFootnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let viewers = stream.participants, viewers > 0 {
                                Label("\(viewers)", systemImage: "eye")
                                    .font(.appFootnote.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func mostActiveCard(_ people: [FeedDashboardSnapshot.Ranked]) -> some View {
        let shown = Array(people.prefix(isWide ? 12 : 6))
        return card(title: "Most active today", icon: "chart.bar", tint: .green, onMore: { onOpenFeed(.following) }) {
            HStack(spacing: -6) {
                ForEach(shown) { person in
                    Button { showingProfile = IdentifiableString(id: person.id) } label: {
                        AvatarView(url: nostr.profiles[person.id]?.pictureURL, pubkey: person.id, size: 40)
                            .overlay(Circle().stroke(Color.platformCardBackground, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name(person.id)), \(person.count) posts")
                }
                if people.count > shown.count {
                    Text("+\(people.count - shown.count)")
                        .font(.appFootnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 14)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func popularCard(_ notes: [FeedDashboardSnapshot.PopularNote]) -> some View {
        card(title: "Popular with your people", icon: "flame", tint: .orange) {
            VStack(spacing: 12) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, item in
                    Button { showingNote = IdentifiableString(id: item.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.appHeadline.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(minWidth: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                if let note = item.note {
                                    Text(name(note.pubkey))
                                        .font(.appFootnote.weight(.semibold))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(note.content.isEmpty ? "Post" : note.content)
                                        .font(.appSubheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                } else {
                                    Text("Loading post…")
                                        .font(.appSubheadline)
                                        .foregroundColor(.secondary)
                                }
                                Label("\(item.people) of your follows", systemImage: "heart")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func trendingCard(_ tags: [FeedDashboardSnapshot.Ranked]) -> some View {
        card(title: "Trending in your circle", icon: "number", tint: .blue) {
            DashboardChipFlow(spacing: 8) {
                ForEach(tags) { tag in
                    Button { showingTag = IdentifiableString(id: tag.id) } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag.id)").font(.appSubheadline)
                            Text("\(tag.count)")
                                .font(.appCaption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("#\(tag.id), \(tag.count) people")
                }
            }
        }
    }

    private func tilesCard(_ tiles: [FeedDashboardSnapshot.Tile]) -> some View {
        // A grid, not a side scroll: on a phone a side scroll hides half the tiles.
        card(title: "From your follows", icon: "square.grid.2x2", tint: .purple) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: isWide ? 6 : 3), spacing: 10) {
                ForEach(tiles) { tile in
                    Button { onOpenFeed(tile.mode) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: tile.mode.symbolName)
                                    .font(.appFootnote)
                                    .foregroundColor(.accentColor)
                                Spacer(minLength: 0)
                                Text("\(tile.count)")
                                    .font(.appHeadline.monospacedDigit())
                            }
                            Text(tile.mode.displayName)
                                .font(.appFootnote.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(tile.preview ?? " ")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformTertiaryGroupedBackground))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tile.mode.displayName), \(tile.count)")
                }
            }
        }
    }

    private var vaultRow: some View {
        Button { openVault {} } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.appHeadline)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your vault").font(.appSubheadline.weight(.semibold))
                    Text(vaultLine)
                        .font(.appFootnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.appFootnote.weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(14)
            .background(cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var vaultLine: String {
        var parts = ["\(Self.compact(stats.loadedEventsCount)) events"]
        if !feed.wotPubkeys.isEmpty { parts.append("Web of Trust \(Self.compact(feed.wotPubkeys.count))") }
        return parts.joined(separator: " · ")
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking at your network's last 24 hours…")
                .font(.appFootnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.appTitle)
                .foregroundColor(.secondary)
            Text(text)
                .font(.appSubheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Pieces

    private func card<Content: View>(title: String, trailing: String? = nil, icon: String, tint: Color,
                                     onMore: (() -> Void)? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(tint)
                Text(title).font(.appHeadline)
                if let trailing {
                    Text(trailing)
                        .font(.appFootnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if let onMore {
                    Button(action: onMore) {
                        Image(systemName: "chevron.right")
                            .font(.appFootnote.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(title)")
                }
            }
            content()
        }
        .padding(14)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.platformCardBackground)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformCardBorder, lineWidth: 1))
    }

    private func name(_ pubkey: String) -> String {
        let profile = nostr.profiles[pubkey]
        if let n = profile?.displayName, !n.isEmpty { return n }
        if let n = profile?.name, !n.isEmpty { return n }
        return String(pubkey.prefix(8)) + "…"
    }

    /// Opens the Relay tab, then whatever list `then` selects, once the tab exists.
    private func openVault(then: @escaping () -> Void) {
        onDismiss()
        NotificationCenter.default.post(name: .havenOpenViewer, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: then)
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(n / 1000)k"
        case 1_000...: return String(format: "%.1fk", Double(n) / 1000)
        default: return "\(n)"
        }
    }
}

/// Wraps the hashtag chips onto as many rows as they need.
private struct DashboardChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
