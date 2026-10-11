import SwiftUI

// MARK: - ThreadedReplyNode

struct ThreadedReplyNode: View {
    let reply: FeedNote
    let allNotes: [FeedNote]
    let depth: Int
    var onReply: ((FeedNote) -> Void)? = nil
    var onQuote: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL, [URL]) -> Void)? = nil
    @Binding var focusedNoteId: String
    let proxy: ScrollViewProxy

    // Expanded engagement data
    var expandedEngagement: Bool = false
    var perNoteReactions: [String: [NostrEvent]] = [:]
    var perNoteReposts: [String: [NostrEvent]] = [:]
    var perNoteZaps: [String: [NostrEvent]] = [:]

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        let childReplies = allNotes.filter { $0.parentEventId == reply.id }
            .sorted(by: { $0.createdAt < $1.createdAt })

        let isCurrentFocused = reply.id == focusedNoteId

        VStack(alignment: .leading, spacing: 8) {
            replyView(isCurrentFocused: isCurrentFocused)

            if !childReplies.isEmpty {
                if depth >= 3 {
                    // Prevent excessive indentation squishing on narrow mobile screens
                    Button {
                        withAnimation(Motion.scrollJump) {
                            focusedNoteId = reply.id
                            proxy.scrollTo(reply.id, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.appSystem(size: 11, weight: .bold))
                            Text("Show \(childReplies.count) more \(childReplies.count == 1 ? "reply" : "replies")")
                                .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color.havenPurple)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        // Thread vertical connecting line
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.25))
                            .frame(width: 1.5)
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(childReplies) { child in
                                ThreadedReplyNode(
                                    reply: child,
                                    allNotes: allNotes,
                                    depth: depth + 1,
                                    onReply: onReply,
                                    onQuote: onQuote,
                                    onProfile: onProfile,
                                    onMedia: onMedia,
                                    focusedNoteId: $focusedNoteId,
                                    proxy: proxy,
                                    expandedEngagement: expandedEngagement,
                                    perNoteReactions: perNoteReactions,
                                    perNoteReposts: perNoteReposts,
                                    perNoteZaps: perNoteZaps
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func replyView(isCurrentFocused: Bool) -> some View {
        let replyProfile = nostrService.profiles[reply.pubkey]
        let rowData = FeedNoteRowData.resolve(
            for: reply,
            feedService: FeedService.shared,
            nostrService: nostrService
        )

        // Check if this reply has engagement to show
        let hasEngagement = expandedEngagement && !isCurrentFocused && (
            !groupedReactionsForReply(reply.id).isEmpty ||
            zapTotalForReply(reply.id).count > 0 ||
            repostCountForReply(reply.id) > 0
        )

        VStack(alignment: .leading, spacing: 0) {
            FeedNoteRow(
                note: reply,
                profile: replyProfile,
                rowData: rowData,
                onReply: { onReply?(reply) },
                onQuote: { onQuote?(reply) },
                onProfile: onProfile,
                onMedia: onMedia,
                showParent: false,
                layoutMode: .wide,
                isFocused: isCurrentFocused
            )

            // Expanded engagement for this reply - inside the note box
            if hasEngagement {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ThreadNoteEngagementRow(
                    reactions: groupedReactionsForReply(reply.id),
                    zapCount: zapTotalForReply(reply.id).count,
                    zapSats: zapTotalForReply(reply.id).sats,
                    repostCount: repostCountForReply(reply.id)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .id(reply.id)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.scrollJump) {
                focusedNoteId = reply.id
                proxy.scrollTo(reply.id, anchor: .center)
            }
        }
    }

    // Per-note engagement helpers for this reply node
    private func groupedReactionsForReply(_ noteId: String) -> [(emoji: String, count: Int)] {
        if configService.config.zapsOnlyMode { return [] }
        let reactions = (perNoteReactions[noteId] ?? []).map { (content: $0.content, pubkey: $0.pubkey, createdAt: $0.created_at) }
        return ReactionGrouping.groups(reactions).map { (emoji: $0.emoji, count: $0.count) }
    }

    private func zapTotalForReply(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            totalSats += Int64(LiveChat.zapAmountSats(receiptTags: zap.tags))
        }
        return (count: zaps.count, sats: totalSats)
    }

    private func repostCountForReply(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }
}
