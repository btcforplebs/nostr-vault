import SwiftUI

struct NoteRow: View {
    let event: NostrEvent
    /// When true, clamp the body to a few lines and append a "Show more"
    /// affordance. Used by compact contexts like the likes/zaps lists.
    var truncate: Bool = false
    /// Layout mode for the note display
    var layoutMode: VaultView.NoteLayoutMode = .expanded
    /// Optional inline engagement data rendered inside the card.
    var reactors: [(pubkey: String, emoji: String)]? = nil
    var latestReactionDate: Date? = nil
    var zappers: [(pubkey: String, amount: Int64)]? = nil
    var reposterPubkeys: [String]? = nil
    var quoterPubkeys: [String]? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @State private var isHovered = false
    @State private var showingReportDialog = false
    @State private var showingReactors = false
    @State private var showingReposters = false
    @State private var showingQuoters = false
    @State private var isExpanded = false

    var cleanContent: String {
        return event.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For kind 6 reposts, parse the embedded JSON to extract the original note
    var repostedEvent: NostrEvent? {
        guard event.kind == 6,
              let data = event.content.data(using: .utf8),
              let inner = try? JSONDecoder().decode(NostrEvent.self, from: data) else {
            return nil
        }
        return inner
    }

    var displayName: String {
        let profile = nostrService.profiles[event.pubkey]
        if let profile = profile {
            return profile.bestName
        }
        return event.pubkey.prefix(8) + "..." + event.pubkey.suffix(4)
    }

    enum NoteType {
        case mine
        case whitelisted
        case tagged

        var label: String {
            switch self {
            case .mine: return "My Note"
            case .whitelisted: return "Whitelisted"
            case .tagged: return "Tagged"
            }
        }

        var icon: String {
            switch self {
            case .mine: return "pencil.line"
            case .whitelisted: return "checkmark.seal.fill"
            case .tagged: return "tag.fill"
            }
        }

        @MainActor var color: Color {
            switch self {
            case .mine: return .havenPurple
            case .whitelisted: return .green
            case .tagged: return .blue
            }
        }
    }

    var noteType: NoteType {
        if event.pubkey == nostrService.activeHexPubkey {
            return .mine
        }
        if configService.whitelistedHexPubkeys.contains(event.pubkey) {
            return .whitelisted
        }
        return .tagged
    }

    var body: some View {
        Group {
            if layoutMode == .compact {
                compactLayout
            } else {
                expandedLayout
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if noteType != .mine {
                Button(action: {
                    showingReportDialog = true
                }) {
                    Label("Report Post", systemImage: "flag.fill")
                }

                Divider()

                Button(action: {
                    blockUser(hexPubkey: event.pubkey)
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .sheet(isPresented: $showingReportDialog) {
            UGCReportingDialog(eventId: event.id, pubkey: event.pubkey, onDismiss: { showingReportDialog = false }) {
                // Background refresh will handle hiding it, but we can proactively trigger update
                nostrService.objectWillChange.send()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .onAppear {
            if nostrService.profiles[event.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [event.pubkey])
            }
        }
    }

    // MARK: - Compact Layout
    /// A condensed single-row layout mirroring the Feed's compact mode:
    /// 32pt avatar, name · time header, two lines of plain text, and a small
    /// media thumbnail. No engagement bar — tapping the row opens the detail view.
    private var compactLayout: some View {
        let urls = event.mediaURLs
        let innerUrls = repostedEvent?.mediaURLs ?? []
        let firstMedia = urls.first ?? innerUrls.first
        let totalMedia = urls.count + innerUrls.count
        let contentToShow: String = {
            if event.kind == 6, cleanContent.isEmpty, let inner = repostedEvent {
                return inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return cleanContent
        }()

        return HStack(alignment: .top, spacing: 8) {
            AvatarView(
                url: nostrService.profiles[event.pubkey]?.pictureURL,
                pubkey: event.pubkey,
                size: 32
            )
            .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Image(systemName: noteType.icon)
                        .font(.appSystem(size: 9))
                        .foregroundColor(noteType.color)

                    Text("· \(timeAgo(from: event.createdAtDate))")
                        .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if event.kind == 6 {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.green.opacity(0.7))
                    }
                    if event.isReply {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(Color.havenPurple.opacity(0.7))
                    }
                }

                if !contentToShow.isEmpty {
                    Text(NostrContentFormatter.resolveMentionsPlainText(contentToShow))
                        .font(.appSystem(size: 14))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .lineSpacing(1)
                }
            }

            Spacer(minLength: 8)

            if let firstMedia = firstMedia {
                ZStack(alignment: .bottomTrailing) {
                    FeedMediaView(url: firstMedia, isThumbnail: true)
                        .frame(width: 60, height: 60)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if totalMedia > 1 {
                        Text("+\(totalMedia - 1)")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.havenPurple.opacity(0.15), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Layout

    private var expandedLayout: some View {
        let avatarSize: CGFloat = layoutMode == .compact ? 32 : 40
        let headerSpacing: CGFloat = layoutMode == .compact ? 8 : 12
        let contentFontSize: CGFloat = layoutMode == .compact ? 14 : 15
        let cardSpacing: CGFloat = layoutMode == .compact ? 8 : 10

        return VStack(alignment: .leading, spacing: cardSpacing) {
            // Header with profile and timestamp
            HStack(alignment: .center, spacing: headerSpacing) {
                AvatarView(
                    url: nostrService.profiles[event.pubkey]?.pictureURL,
                    pubkey: event.pubkey,
                    size: avatarSize
                )
                .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.appSystem(size: 14, weight: .semibold, design: .default))
                            .lineLimit(1)

                        if event.kind == 6 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.2.squarepath")
                                    .font(.appSystem(size: 10, weight: .semibold))
                                Text("Reposted")
                                    .font(.appSystem(size: 11, weight: .medium))
                            }
                            .foregroundColor(.green)
                        }

                        if event.isReply {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.appSystem(size: 10, weight: .semibold))
                                Text("Reply")
                                    .font(.appSystem(size: 11, weight: .medium))
                            }
                            .foregroundColor(Color.havenPurple.opacity(0.7))
                        }

                        Image(systemName: noteType.icon)
                            .font(.appCaption2)
                            .foregroundColor(noteType.color)

                        Spacer()

                        Text(timeAgo(from: event.createdAtDate))
                            .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }
                }
            }

            // Repost: show the inner note's content
            if let inner = repostedEvent {
                RepostedNoteView(inner: inner)
                    .environmentObject(nostrService)
            } else {
                // Regular note content
                let urls = event.mediaURLs
                let links = event.linkURLs

                if !cleanContent.isEmpty {
                    Text(NostrContentFormatter.format(cleanContent, mediaURLs: urls))
                        .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                        .foregroundColor(Color(red: 1, green: 1, blue: 1))
                        .lineSpacing(2)
                        .lineLimit(truncate && !isExpanded ? 8 : nil)
                        .fixedSize(horizontal: false, vertical: true)

                    if truncate && !isExpanded && cleanContent.count > 240 {
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded = true } }) {
                            Text("Show more")
                                .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.havenPurple)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Media previews (photos, GIFs, videos)
                if !urls.isEmpty {
                    if urls.count == 1 {
                        FeedMediaView(url: urls[0], maxHeight: 300, portraitMaxHeight: 400, isThumbnail: false)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        TabView {
                            ForEach(urls, id: \.absoluteString) { url in
                                FeedMediaView(url: url, maxHeight: 300, portraitMaxHeight: 400, isThumbnail: false)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .transition(.opacity.animation(.spring(response: 0.25, dampingFraction: 0.75)))
                            }
                        }
                        .mediaTabViewStyleCompat()
                        .frame(height: 300)
                    }
                }

                // Link preview
                if !links.isEmpty {
                    LinkPreviewCard(url: links[0])
                }
            }

            // Compact inline engagement bar
            // In Zaps Only mode reactions are dropped from both the bar and its visibility check.
            let rxList = configService.config.zapsOnlyMode ? [] : (reactors ?? [])
            let zpList = zappers ?? []
            let rpList = reposterPubkeys ?? []
            let qtList = quoterPubkeys ?? []
            if !rxList.isEmpty || !zpList.isEmpty || !rpList.isEmpty || !qtList.isEmpty {
                engagementBar(reactors: rxList, zaps: zpList, reposters: rpList, quoters: qtList)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.12), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .clipped()
    }

    private func avatarGradientForType(_ type: NoteType) -> LinearGradient {
        switch type {
        case .mine:
            return LinearGradient(
                gradient: Gradient(colors: [
                    .havenPurple,
                    .havenPurpleLight
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .whitelisted:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.8, blue: 0.6),
                    Color(red: 0.1, green: 0.7, blue: 0.5)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tagged:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.5, blue: 0.8),
                    Color(red: 0.3, green: 0.6, blue: 1.0)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Inline Engagement Bar

    @ViewBuilder
    private func engagementBar(reactors: [(pubkey: String, emoji: String)], zaps: [(pubkey: String, amount: Int64)], reposters: [String], quoters: [String]) -> some View {
        let uniqueReactors: [(pubkey: String, emoji: String)] = {
            var seen = Set<String>()
            return reactors.filter { seen.insert($0.pubkey).inserted }
        }()
        let uniqueZapperPubkeys: [String] = {
            var seen = Set<String>()
            return zaps.compactMap { z in
                if seen.contains(z.pubkey) { return nil }
                seen.insert(z.pubkey)
                return z.pubkey
            }
        }()
        let uniqueReposters: [String] = {
            var seen = Set<String>()
            return reposters.filter { seen.insert($0).inserted }
        }()
        let uniqueQuoters: [String] = {
            var seen = Set<String>()
            return quoters.filter { seen.insert($0).inserted }
        }()
        let totalSats = zaps.reduce(Int64(0)) { $0 + $1.amount }

        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.top, 6)

        HStack(spacing: 14) {
            // Reactions — hidden entirely in Zaps Only mode
            if !uniqueReactors.isEmpty && !configService.config.zapsOnlyMode {
                Button {
                    showingReactors = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.pink)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReactors.prefix(3).enumerated()), id: \.offset) { _, reactor in
                                AvatarView(url: nostrService.profiles[reactor.pubkey]?.pictureURL, pubkey: reactor.pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReactors.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.pink.opacity(0.8))

                        if let date = latestReactionDate {
                            Text(timeAgo(from: date))
                                .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Reposts
            if !uniqueReposters.isEmpty {
                Button {
                    showingReposters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReposters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReposters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }

            // Quotes
            if !uniqueQuoters.isEmpty {
                Button {
                    showingQuoters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.blue)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueQuoters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueQuoters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }

            // Zaps
            if !uniqueZapperPubkeys.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.appSystem(size: 10, weight: .bold))
                        .foregroundColor(.orange)

                    HStack(spacing: -4) {
                        ForEach(Array(uniqueZapperPubkeys.prefix(3).enumerated()), id: \.element) { _, pubkey in
                            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                        }
                    }

                    Text(Self.formatSats(totalSats))
                        .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                }
            }

            Spacer()
        }
        .padding(.top, 6)
        .sheet(isPresented: $showingReactors) {
            ReactorsListView(reactors: uniqueReactors, onDismiss: { showingReactors = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingReposters) {
            RepostersListView(pubkeys: uniqueReposters, onDismiss: { showingReposters = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingQuoters) {
            QuotersListView(pubkeys: uniqueQuoters, onDismiss: { showingQuoters = false })
                .environmentObject(nostrService)
        }
        .onAppear {
            let allPubkeys = uniqueReactors.map(\.pubkey) + uniqueZapperPubkeys + uniqueReposters + uniqueQuoters
            let missing = allPubkeys.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: Array(Set(missing)))
            }
        }
    }

    private static func formatSats(_ sats: Int64) -> String {
        if sats >= 1_000_000 {
            let m = Double(sats) / 1_000_000.0
            return String(format: "%.1fM sats", m)
        } else if sats >= 10_000 {
            let k = Double(sats) / 1_000.0
            return String(format: "%.1fK sats", k)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return (formatter.string(from: NSNumber(value: sats)) ?? "\(sats)") + " sats"
        }
    }
}

struct RepostedNoteView: View {
    let inner: NostrEvent
    @EnvironmentObject var nostrService: NostrService

    private var innerDisplayName: String {
        if let profile = nostrService.profiles[inner.pubkey] {
            return profile.bestName
        }
        return inner.pubkey.prefix(8) + "..." + inner.pubkey.suffix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inner note author header
            HStack(spacing: 8) {
                AvatarView(
                    url: nostrService.profiles[inner.pubkey]?.pictureURL,
                    pubkey: inner.pubkey,
                    size: 28
                )
                .overlay(Circle().stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5))

                Text(innerDisplayName)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Text(timeAgo(from: inner.createdAtDate))
                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Inner note content
            let urls = inner.mediaURLs
            let links = inner.linkURLs
            let content = inner.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                Text(NostrContentFormatter.format(content, mediaURLs: urls))
                    .font(.appSystem(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))
                    .lineSpacing(2)
                    .lineLimit(nil)
            }

            // Media previews
            if !urls.isEmpty {
                if urls.count == 1 {
                    FeedMediaView(url: urls[0], maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    TabView {
                        ForEach(urls.prefix(4), id: \.absoluteString) { url in
                            FeedMediaView(url: url, maxHeight: 250, portraitMaxHeight: 350, isThumbnail: false)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .transition(.opacity.animation(.spring(response: 0.25, dampingFraction: 0.75)))
                        }
                    }
                    .mediaTabViewStyleCompat()
                    .frame(height: 250)
                }
            }

            // Link preview
            if !links.isEmpty {
                LinkPreviewCard(url: links[0])
            }
        }
        .padding(10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.14))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.2, green: 0.2, blue: 0.25), lineWidth: 0.5)
        )
        .onAppear {
            if nostrService.profiles[inner.pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [inner.pubkey])
            }
        }
    }

    func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
