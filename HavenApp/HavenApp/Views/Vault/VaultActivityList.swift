import SwiftUI

// MARK: - "Vault" list

extension VaultView {

    /// The Vault tab's first list: replies, mentions, likes, zaps, reposts and
    /// follows from everyone, newest first, the way a notifications page reads.
    var activityList: some View {
        let zapsOnly = configService.config.zapsOnlyMode
        let lines = zapsOnly ? displayActivity.filter { $0.kind != .reaction } : displayActivity
        let isLoading = nostrService.isFetching || relayManager.isBooting || !activityHasLoadedOnce
        return Group {
            if lines.isEmpty && isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)
                    Text(relayManager.isBooting ? relayManager.bootStatusMessage.isEmpty ? "Starting relay..." : relayManager.bootStatusMessage : "Loading your vault...")
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 80)
            } else if lines.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: VaultMode.activity.symbol)
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text("Nothing new yet")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text("Replies, likes, zaps and new followers land here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(lines) { line in
                        activityLink(line)
                            .padding(.horizontal, 16)
                            .onAppear {
                                if line.id == lines.last?.id { loadMoreActivity() }
                            }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A line opens what it's about: the post (theirs, or yours they reacted
    /// to), the person when it's a follow or a zap on your profile, or the
    /// Followers list when several followed you that day.
    @ViewBuilder
    private func activityLink(_ line: VaultActivity) -> some View {
        let row = VaultActivityRow(line: line, isUnread: line.createdAt > activityUnreadSince)
            .relayFocusOutline(line.openId != nil && focusedEventId == line.openId)
        #if os(iOS)
        if let id = line.openId, let event = nostrService.events.first(where: { $0.id == id }) {
            NoteNavigationLink(note: FeedNote(
                id: event.id,
                pubkey: event.pubkey,
                content: event.content,
                createdAt: event.createdAtDate,
                tags: event.tags,
                kind: event.kind
            )) { row }
            .buttonStyle(.plain)
        } else {
            Button { openActivity(line) } label: { row }
                .buttonStyle(.plain)
        }
        #else
        Button { openActivity(line) } label: { row }
            .buttonStyle(.plain)
        #endif
    }

    private func openActivity(_ line: VaultActivity) {
        if let id = line.openId {
            openNote(id)
        } else if line.kind == .follow && line.actors.count > 1 {
            withAnimation(Motion.toggle) { viewMode = .followers }
        } else if let who = line.actors.first {
            showingProfilePubkey = who
        }
    }

    /// Shows 50 more lines, then pages older events in from the relay.
    private func loadMoreActivity() {
        if displayActivity.count >= maxDisplayedItems {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        } else if !nostrService.isFetching {
            loadMore()
        }
    }

    /// The account's "seen up to" time for the Vault list's unread dots.
    private var activitySeenKey: String { "vaultActivitySeenAt.\(followersOwnerHex)" }

    /// Called when the Vault list comes on screen or leaves it. Arriving keeps
    /// the last visit's time, so lines newer than it show as unread; both
    /// move the mark to now.
    func activityVisit(arriving: Bool) {
        let now = Date().timeIntervalSince1970
        if arriving {
            let last = UserDefaults.standard.double(forKey: activitySeenKey)
            // A first visit marks nothing: everything would be "new".
            activityUnreadSince = Int64(last > 0 ? last : now)
        }
        UserDefaults.standard.set(now, forKey: activitySeenKey)
    }
}

// MARK: - Row

/// One notification-style line: what happened, who did it, what it was about.
struct VaultActivityRow: View {
    let line: VaultActivity
    var isUnread = false
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    private static let avatarLimit = 6

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    avatars
                    Spacer(minLength: 4)
                    Text(timeAgo)
                        .font(.appSystem(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    if isUnread {
                        Circle()
                            .fill(Color.havenPurple)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                headline
                    .fixedSize(horizontal: false, vertical: true)
                previewText
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(isUnread ? 0.06 : 0.015)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.havenPurple.opacity(configService.config.useOLED ? 0.30 : 0.12),
                    lineWidth: configService.config.useOLED ? 1.5 : 0.8
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "New" : "")
    }

    // MARK: Pieces

    private var badge: some View {
        Image(systemName: style.icon)
            .font(.appSystem(size: 15, weight: .bold))
            .foregroundColor(style.color)
            .frame(width: 34, height: 34)
            .background(Circle().fill(style.color.opacity(0.15)))
            .accessibilityHidden(true)
    }

    private var avatars: some View {
        HStack(spacing: -8) {
            ForEach(line.actors.prefix(Self.avatarLimit), id: \.self) { pubkey in
                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 30)
                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2))
            }
            if line.actors.count > Self.avatarLimit {
                Text("+\(line.actors.count - Self.avatarLimit)")
                    .font(.appSystem(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 14)
            }
        }
        .accessibilityHidden(true)
    }

    private var headline: some View {
        (Text(who).fontWeight(.bold) + Text(" " + verb))
            .font(.appSystem(size: 15))
            .foregroundColor(.primary)
    }

    /// Their words in full colour; your own post, when they only reacted to
    /// it, quieter and behind a rule, so the two never read alike.
    @ViewBuilder
    private var previewText: some View {
        let text = readablePreview
        if !text.isEmpty {
            if aboutYourPost {
                Text(text)
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(style.color.opacity(0.5)).frame(width: 3)
                    }
            } else {
                Text(text)
                    .font(.appSystem(size: 15))
                    .foregroundColor(.primary)
                    .lineLimit(4)
            }
        }
    }

    // MARK: Words

    /// The preview with `nostr:` links made readable: people become @names,
    /// links to posts drop out (a one-line preview can't show them).
    private var readablePreview: String {
        guard line.preview.contains("nostr:") else { return line.preview }
        return line.preview.split(separator: " ").compactMap { word -> String? in
            guard word.hasPrefix("nostr:") else { return String(word) }
            let id = String(word.dropFirst(6)).trimmingCharacters(in: .punctuationCharacters)
            if let pubkey = QuoteReference.profilePubkey(fromBech32: id) { return "@" + name(pubkey) }
            return nil
        }.joined(separator: " ")
    }

    /// Likes, reposts and plain zaps quote your post; everything else quotes them.
    private var aboutYourPost: Bool {
        switch line.kind {
        case .reaction, .repost: return true
        // Folded zaps ("zap-<post>") carry no words of their own.
        case .zap: return line.id.hasPrefix("zap-")
        default: return false
        }
    }

    private func name(_ pubkey: String) -> String {
        nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }

    private var who: String {
        let actors = line.actors
        switch actors.count {
        case 0: return "Someone"
        case 1: return name(actors[0])
        case 2: return "\(name(actors[0])) and \(name(actors[1]))"
        default: return "\(name(actors[0])) and \(actors.count - 1) others"
        }
    }

    private var verb: String {
        switch line.kind {
        case .reply: return "replied to you"
        case .mention: return "mentioned you"
        case .quote: return "quoted your note"
        case .reaction:
            let emojis = reactionEmojiSummary(line.emojis, limit: 3)
            return emojis == "❤️" ? "liked your note" : "reacted \(emojis) to your note"
        case .repost: return "reposted your note"
        case .zap:
            let sats = line.sats.formatted(.number)
            return line.openId == nil ? "zapped you \(sats) sats" : "zapped your note \(sats) sats"
        case .article: return "tagged you in an article"
        case .highlight: return "highlighted you"
        case .follow: return "followed you"
        }
    }

    private var style: (icon: String, color: Color) {
        switch line.kind {
        case .reply: return ("arrowshape.turn.up.left.fill", .havenPurple)
        case .mention: return ("at", .havenPurple)
        case .quote: return ("quote.bubble.fill", .havenPurple)
        case .reaction: return ("heart.fill", .pink)
        case .repost: return ("arrow.2.squarepath", Color(red: 0.2, green: 0.8, blue: 0.6))
        case .zap: return ("bolt.fill", .orange)
        case .article: return ("doc.richtext", .havenPurple)
        case .highlight: return ("highlighter", .yellow)
        case .follow: return ("person.badge.plus", .havenPurple)
        }
    }

    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(line.createdAt)), relativeTo: Date())
    }
}
