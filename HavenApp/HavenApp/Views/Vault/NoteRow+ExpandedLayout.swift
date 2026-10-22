import SwiftUI

/// Measures a note body's fully unclamped height so `truncate` can tell
/// whether its `lineLimit` actually cut anything, rather than guessing from
/// character count.
private struct FullTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ClampedTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
                let urls = event.mediaURLs
                let links = LinkCards.shown(event.linkURLs)

                if !cleanContent.isEmpty {
                    let formattedContent = NostrContentFormatter.format(cleanContent, mediaURLs: urls + links)
                    Group {
                        if truncate {
                            Text(formattedContent)
                                .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineSpacing(2)
                                .lineLimit(isExpanded ? nil : 8)
                                .fixedSize(horizontal: false, vertical: true)
                                .background(
                                    Text(formattedContent)
                                        .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                        .lineSpacing(2)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .hidden()
                                        .background(GeometryReader { geo in
                                            Color.clear.preference(key: FullTextHeightKey.self, value: geo.size.height)
                                        })
                                )
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: ClampedTextHeightKey.self, value: geo.size.height)
                                })
                                .onPreferenceChange(FullTextHeightKey.self) { fullContentHeight = $0 }
                                .onPreferenceChange(ClampedTextHeightKey.self) { clampedContentHeight = $0 }
                        } else {
                            Text(formattedContent)
                                .font(.appSystem(size: contentFontSize, weight: .regular, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if truncate && !isExpanded && isContentClamped {
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

                // Link previews, one per link — the text no longer shows them.
                ForEach(links, id: \.self) { url in
                    LinkPreviewCard(url: url)
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
