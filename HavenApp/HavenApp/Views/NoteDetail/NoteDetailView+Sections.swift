import SwiftUI
import Combine

extension NoteDetailView {
    func mainNoteSection(proxy: ScrollViewProxy) -> some View {
        let profile = nostrService.profiles[focusedNote.pubkey]
        let rowData = FeedNoteRowData.resolve(
            for: focusedNote,
            feedService: feedService,
            nostrService: nostrService
        )
        let hasEngagement = (!detailedReactions.isEmpty && !configService.config.zapsOnlyMode) || !detailedZaps.isEmpty || !detailedReposts.isEmpty

        return mainNoteLayout(profile: profile, rowData: rowData, hasEngagement: hasEngagement)
            .transition(.asymmetric(
                insertion: AnyTransition.opacity.combined(with: AnyTransition.scale(scale: 0.95)),
                removal: AnyTransition.opacity
            ))
            .id(focusedNote.id)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func mainNoteLayout(profile: FeedProfile?, rowData: FeedNoteRowData, hasEngagement: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedNoteRow(
                note: focusedNote,
                profile: profile,
                rowData: rowData,
                onReply: {
                    composeContext = ComposeContext(replyTo: feedService.replyTarget(for: focusedNote), quoteTo: nil)
                },
                onQuote: {
                    composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: focusedNote))
                },
                onProfile: { pubkey in
                    showingProfilePubkey = pubkey
                },
                onMedia: { url, urls in
                    showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                },
                showParent: false,
                layoutMode: .wide,
                isFocused: true,
                suppressCardStyling: true
            )

            if hasEngagement {
                engagementDetailSection
                    .transition(.opacity)
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
                .stroke(Color.havenPurple, lineWidth: 2.0)
        )
        .shadow(color: Color.havenPurple.opacity(0.35), radius: 8)
    }

    @ViewBuilder
    func threadHistory(proxy: ScrollViewProxy) -> some View {
        if condensedReplies {
            // The conversation above, one line per note, oldest at the top.
            VStack(alignment: .leading, spacing: 2) {
                // Notes above it by someone you blocked are left out, as in
                // the full history.
                ForEach(BlockedPeople.visibleNotes(dynamicParents, blocked: configService.activeAccountBlockedHexPubkeys) { $0.pubkey }) { parent in
                    condensedLine(for: parent, depth: 0, proxy: proxy)
                }
            }
            .threadCard()
            .padding(.horizontal, 16)
        } else {
            fullThreadHistory(proxy: proxy)
        }
    }

    private func fullThreadHistory(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Notes above it by someone you blocked are left out.
            ForEach(BlockedPeople.visibleNotes(dynamicParents, blocked: configService.activeAccountBlockedHexPubkeys) { $0.pubkey }) { parent in
                let parentProfile = nostrService.profiles[parent.pubkey]

                Group {
                    let rowData = FeedNoteRowData.resolve(
                        for: parent,
                        feedService: feedService,
                        nostrService: nostrService
                    )

                    // Check if this parent has engagement to show
                    let hasEngagement = expandedEngagement && parent.id != focusedNoteId && (
                        !groupedReactionsForNote(parent.id).isEmpty ||
                        zapTotalForNote(parent.id).count > 0 ||
                        repostCountForNote(parent.id) > 0
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        FeedNoteRow(
                            note: parent,
                            profile: parentProfile,
                            rowData: rowData,
                            onReply: {
                                composeContext = ComposeContext(replyTo: parent, quoteTo: nil)
                            },
                            onQuote: {
                                composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: parent))
                            },
                            onProfile: { pubkey in
                                showingProfilePubkey = pubkey
                            },
                            onMedia: { url, urls in
                                showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                            },
                            showParent: false,
                            layoutMode: .wide,
                            isFocused: parent.id == focusedNoteId
                        )

                        // Expanded engagement for parent notes - inside the note box
                        if hasEngagement {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(height: 0.5)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)

                            ThreadNoteEngagementRow(
                                reactions: groupedReactionsForNote(parent.id),
                                zapCount: zapTotalForNote(parent.id).count,
                                zapSats: zapTotalForNote(parent.id).sats,
                                repostCount: repostCountForNote(parent.id)
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                        }
                    }
                    .id(parent.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectAndScrollToNote(parent.id, proxy: proxy)
                    }
                    .padding(.horizontal, 16)
                }
            }

            if isLoadingParents {
                FeedNoteSkeletonRow()
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Whether the note shown full size is by someone you blocked. Read from
    /// the live block list, so a block made on this page applies at once.
    var focusedNoteBlockState: BlockedPeople.FocusedNote {
        BlockedPeople.focusedNote(author: focusedNote.pubkey, isOpenedNote: focusedNote.id == note.id,
                                  blocked: configService.activeAccountBlockedHexPubkeys)
    }

    /// Takes the place of the note you opened once you block its author.
    /// Their replies and quotes go with it.
    var blockedNotePlaceholder: some View {
        Label("You blocked this person", systemImage: "hand.raised.fill")
            .font(.appSystem(size: 14, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.platformSecondaryGroupedBackground)
            .cornerRadius(12)
            .id(note.id)
            .padding(.horizontal, 16)
    }

    /// Quotes, highlights and other responses, under the replies.
    @ViewBuilder
    var otherResponsesSection: some View {
        // Read at draw time, so blocking someone takes their quotes out at once.
        let shown = BlockedPeople.visibleNotes(otherResponses, blocked: configService.activeAccountBlockedHexPubkeys) { $0.pubkey }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quotes & highlights")
                    .font(.appSystem(size: 15, weight: .bold))
                    .padding(.horizontal, 16)
                ForEach(shown) { response in
                    OtherResponseCard(note: response, profile: nostrService.profiles[response.pubkey])
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 20)
        }
    }

    func repliesSection(proxy: ScrollViewProxy) -> some View {
        // One pass over everything in memory per redraw; this used to run
        // four times, each a full scan of up to 10,000 notes, every time the
        // live feed changed.
        let all = allThreadNotes
        let replies = threadReplies(in: all)
        let context = contextNoteIds
        // What the views draw from: the opened note, the notes above it, and
        // the replies under it that pass `threadReplies`.
        let pool = all.filter { context.contains($0.id) } + replies
        let targetId = replyTargetId
        let currentReplies = pool.filter { $0.parentEventId == targetId }
            .sorted(by: { $0.createdAt < $1.createdAt })

        return VStack(alignment: .leading, spacing: 12) {
            // Replies already in memory — the one you just posted included —
            // show at once. The spinner is only for an empty page.
            if isLoadingReplies && currentReplies.isEmpty {
                // Subtle loading indicator — replies are being buffered
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.havenPurple)
                    Text("Loading replies\u{2026}")
                        .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .transition(.opacity)
            } else if currentReplies.isEmpty {
                Text("No replies yet")
                    .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .transition(.opacity)
            } else {
                Text("Replies")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.bottom, 2)
                    .padding(.horizontal, 16)

                repliesList(currentReplies, pool: pool, proxy: proxy)
            }
        }
    }

    /// The reply tree. Full: every reply keeps its own card and its own action
    /// bar. Condensed: one card of lines, nested under what they answer; tap
    /// a line and it becomes the note you are reading, full size.
    @ViewBuilder
    private func repliesList(_ currentReplies: [FeedNote], pool: [FeedNote], proxy: ScrollViewProxy) -> some View {
        if condensedReplies {
            let tree = FeedThreadGrouping.replyTree(under: repliesParentId, in: pool)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tree) { entry in
                    condensedLine(for: entry.note, depth: entry.depth, pool: pool, proxy: proxy)
                }
            }
            .threadCard()
            .padding(.horizontal, 16)
            .transition(.opacity)
        } else {
            fullRepliesList(currentReplies, pool: pool, proxy: proxy)
        }
    }

    /// What replies answer: the focused note, or the note a bare repost carries.
    private var repliesParentId: String {
        (focusedNote.kind == 6 && focusedNote.repostedEventId != nil) ? focusedNote.repostedEventId! : focusedNote.id
    }

    /// One condensed line, as the threaded feed draws it: a bare repost shows
    /// the note it carries, credited to its author.
    private func condensedLine(for note: FeedNote, depth: Int, pool: [FeedNote] = [], proxy: ScrollViewProxy) -> some View {
        let rowData = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
        let original = (note.kind == 6 && note.content.isEmpty) ? rowData.resolvedOriginal : nil
        let shown = original ?? note
        let replyCount = pool.reduce(0) { $0 + ($1.parentEventId == note.id ? 1 : 0) }
        let override = original.map { $0.condensedTitle ?? $0.content }
        let live = LiveNoteCleanup.cleaned(content: override ?? shown.content, mediaURLs: shown.mediaURLs,
                                           find: { feedService.findNote(id: $0) })
        return CondensedNoteLine(
            note: note,
            profile: nostrService.profiles[shown.pubkey],
            displayPubkey: original?.pubkey,
            original: original,
            depth: depth,
            style: .plain,
            replyCount: replyCount,
            contentOverride: live?.content ?? override,
            postedAt: original.map { $0.originalCreatedAt ?? $0.createdAt },
            mediaURLs: live?.mediaURLs ?? shown.mediaURLs,
            engagement: CondensedEngagement(
                reactions: rowData.zapsOnlyMode ? 0 : rowData.stats.reactions,
                reposts: rowData.stats.reposts
            ),
            onProfile: { showingProfilePubkey = $0 },
            onTap: { selectAndScrollToNote(note.id, proxy: proxy) }
        )
        .id(note.id)
    }

    private func fullRepliesList(_ currentReplies: [FeedNote], pool: [FeedNote], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                ForEach(currentReplies) { reply in
                    ThreadedReplyNode(
                        reply: reply,
                        allNotes: pool,
                        depth: 1,
                        onReply: { target in
                            composeContext = ComposeContext(replyTo: target, quoteTo: nil)
                        },
                        onQuote: { target in
                            composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: target))
                        },
                        onProfile: { pubkey in
                            showingProfilePubkey = pubkey
                        },
                        onMedia: { url, urls in
                            showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                        },
                        focusedNoteId: $focusedNoteId,
                        proxy: proxy,
                        expandedEngagement: expandedEngagement,
                        perNoteReactions: perNoteReactions,
                        perNoteReposts: perNoteReposts,
                        perNoteZaps: perNoteZaps
                    )
                    .padding(.horizontal, 16)
                }
        }
        .transition(.opacity)
    }
    
    @ViewBuilder
    private func mediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            FeedMediaView(
                url: urls[0],
                onTap: { showingMediaUrl = IdentifiableURL(url: urls[0], allURLs: urls) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        } else {
            MediaPagerView(items: urls) { url in
                FeedMediaView(
                    url: url,
                    onTap: { showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) },
                    maxHeight: 400,
                    isThumbnail: false
                )
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                #if os(iOS)
                .transition(.opacity.animation(Motion.media))
                #endif
            }
            .frame(height: 400)
            .padding(.top, 4)
        }
    }

    private func actionButton(icon: String, color: Color = .secondary, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(color)
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, (count ?? 0) > 0 ? 10 : 0)
            .frame(minWidth: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
