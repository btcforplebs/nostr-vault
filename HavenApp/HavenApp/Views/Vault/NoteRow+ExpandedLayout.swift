import SwiftUI

/// Full heights of a note's text pieces, by segment index, plus one line's
/// height at `NoteRow.lineHeightKey`, so `NoteClamp` can count lines.
private struct SegmentHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension NoteRow {
    // MARK: - Expanded Layout

    var expandedLayout: some View {
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

                        if event.isFromNostrVault {
                            NostrVaultBadge()
                        }

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
                // An old "Share as a note" live post: its playlist and cover
                // leave the text and the cards (LiveNoteCleanup).
                let live = LiveNoteCleanup.cleaned(content: cleanContent, mediaURLs: event.mediaURLs,
                                                   linkURLs: event.linkURLs,
                                                   find: { FeedService.shared.findNote(id: $0) })
                let urls = live?.mediaURLs ?? event.mediaURLs
                let links = LinkCards.shown(live?.linkURLs ?? event.linkURLs)

                // Each link's card sits where the link was written. Collapsed,
                // the text pieces share one 8-line budget, so the clamp still
                // cuts at 8 lines however the text is split around cards.
                let segments = NoteURLs.segments(live?.content ?? cleanContent, cards: links)
                let collapsed = truncate && !isExpanded
                let plan = NoteClamp.plan(segments, lines: measuredLines, budget: 8)
                if !segments.isEmpty {
                    VStack(alignment: .leading, spacing: cardSpacing) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, segment in
                            let show = collapsed ? plan.shows[i] : .full
                            if show != .hidden {
                                switch segment {
                                case .text(let piece):
                                    Text(NostrContentFormatter.format(piece, mediaURLs: urls))
                                        .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                        .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                        .lineSpacing(2)
                                        .lineLimit(show.lineLimit)
                                        .fixedSize(horizontal: false, vertical: true)
                                case .link(let url):
                                    LinkPreviewCard(url: url)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if truncate {
                            // Every text piece at full length, unseen, to count its lines.
                            VStack(alignment: .leading, spacing: 0) {
                                Text("A")
                                    .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(key: SegmentHeightsKey.self, value: [Self.lineHeightKey: geo.size.height])
                                    })
                                ForEach(Array(segments.enumerated()), id: \.offset) { i, segment in
                                    if case .text(let piece) = segment {
                                        Text(NostrContentFormatter.format(piece, mediaURLs: urls))
                                            .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                            .lineSpacing(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .background(GeometryReader { geo in
                                                Color.clear.preference(key: SegmentHeightsKey.self, value: [i: geo.size.height])
                                            })
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hidden()
                        }
                    }
                    .onPreferenceChange(SegmentHeightsKey.self) { segmentHeights = $0 }

                    if collapsed && plan.cut {
                        Button(action: { withAnimation(Motion.panel) { isExpanded = true } }) {
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
                            .meshMediaNote(author: event.pubkey, tags: event.tags)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        MediaPagerView(items: urls) { url in
                            FeedMediaView(url: url, maxHeight: 300, portraitMaxHeight: 400, isThumbnail: false)
                                .meshMediaNote(author: event.pubkey, tags: event.tags)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                #if os(iOS)
                                .transition(.opacity.animation(Motion.media))
                                #endif
                        }
                        .frame(height: 300)
                    }
                }

                // Quoted notes and articles
                QuotedEventsView(identifiers: event.quotedEventIds, content: event.content)
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
                // Zero mouse feedback on the app's densest, most-clicked element —
                // `isHovered` was tracked and never read. Same tint level as
                // ProfileResultRow's hover state, for one hover language app-wide.
                Color.white.opacity(isHovered ? 0.04 : 0)
            }
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                // Matches the feed's expanded note card (non-reply weight).
                .stroke(
                    Color.havenPurple.opacity(configService.config.useOLED ? 0.30 : 0.12),
                    lineWidth: configService.config.useOLED ? 1.5 : 0.8
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .animation(Motion.control, value: isHovered)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .onHover { isHovered = $0 }
        .clipped()
    }
}
