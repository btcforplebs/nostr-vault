import SwiftUI

/// Engagement counts shown beneath a condensed line. Zero fields simply don't
/// draw, so a caller that has no data can pass `.none`.
struct CondensedEngagement: Equatable {
    var reactions: Int = 0
    var reposts: Int = 0
    var zaps: Int = 0
    var topEmoji: String? = nil

    static let none = CondensedEngagement()

    var isEmpty: Bool { reactions == 0 && reposts == 0 && zaps == 0 }
}

/// The single condensed representation of a note.
///
/// Condensed is a property of the feed and nothing else: the feed's condensed
/// and threaded layouts both draw through here, and the thread view is always
/// expanded so a reply is one tap from wherever you landed. Keeping density on
/// one axis is what stops the two surfaces from disagreeing about how dense
/// "condensed" is.
struct CondensedNoteLine: View {
    enum Style {
        /// Standalone row in the feed: its own bordered card.
        case card
        /// A line inside a thread card, which owns the chrome instead.
        case plain
    }

    let note: FeedNote
    let profile: FeedProfile?
    /// The author to credit when it isn't `note.pubkey` — a bare kind-6 repost
    /// shows the original author, not the reposter.
    var displayPubkey: String? = nil

    /// 0 is a root or standalone note; each step indents under a thread rail.
    var depth: Int = 0
    var style: Style = .card
    /// Draws the purple selection treatment — the focused note in a thread card.
    var isFocused: Bool = false
    /// Replies in this thread directly under this note.
    var replyCount: Int = 0
    /// Text to show instead of `note.content` — an article's title, or the
    /// original note's body behind an empty repost.
    var contentOverride: String? = nil
    /// Media for the thumbnail. Callers resolve reposts before passing it.
    var mediaURLs: [URL] = []
    var engagement: CondensedEngagement = .none
    var showsMediaThumbnail: Bool = true

    var onProfile: ((String) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @EnvironmentObject private var configService: ConfigService

    private var isOLED: Bool { configService.config.useOLED }
    private var isRoot: Bool { depth == 0 }

    /// The root anchors the line; replies step in under it. Capped by the
    /// grouper so a deep argument can never indent content off-screen.
    private var indentWidth: CGFloat { CondensedNoteLine.indentWidth(forDepth: depth) }

    /// One source for the indent so a line and the full row that replaces it
    /// when tapped sit on the same left edge.
    static func indentWidth(forDepth depth: Int) -> CGFloat {
        CGFloat(min(depth, FeedThreadGrouping.maxDepth)) * 14
    }

    /// The rail that ties a reply back to what it answers, drawn standalone so
    /// an expanded row can keep the same thread line a condensed one has.
    static func rail(isOLED: Bool) -> some View {
        Rectangle()
            .fill(Color.havenPurple.opacity(isOLED ? 0.35 : 0.22))
            .frame(width: 1.5)
            .padding(.trailing, 8)
            .accessibilityHidden(true)
    }

    private var avatarSize: CGFloat { CondensedNoteLine.avatarSize(forDepth: depth) }

    /// One source for the avatar size so a line and the full row that
    /// replaces it when tapped can match it exactly — opening a line adds an
    /// action bar, not a size change.
    static func avatarSize(forDepth depth: Int) -> CGFloat {
        depth == 0 ? 32 : 26
    }
    private var nameSize: CGFloat { isRoot ? 13 : 12 }
    private var bodySize: CGFloat { isRoot ? 14 : 13 }
    private var bodyLineLimit: Int { isRoot ? 3 : 2 }

    private var displayContent: String {
        contentOverride ?? note.content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if depth > 0 {
                threadRail
            }

            HStack(alignment: .top, spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: authorPubkey, size: avatarSize)
                    .contentShape(Circle())
                    .onTapGesture { onProfile?(authorPubkey) }
                    .accessibilityLabel(Text("Profile of \(displayName)"))

                VStack(alignment: .leading, spacing: 2) {
                    headerRow
                    bodyText
                    engagementRow
                }

                Spacer(minLength: 8)

                if showsMediaThumbnail, let firstMedia = mediaURLs.first {
                    mediaThumbnail(firstMedia)
                }
            }
            .padding(.horizontal, style == .card ? 12 : 8)
            .padding(.vertical, style == .card ? 8 : 6)
            .background(rowBackground)
            .overlay(rowBorder)
        }
        .padding(.leading, indentWidth)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }

    // MARK: - Pieces

    /// The vertical line that ties a reply back to what it answers.
    private var threadRail: some View {
        CondensedNoteLine.rail(isOLED: isOLED)
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text(displayName)
                .font(.appSystem(size: nameSize, weight: .semibold))
                .foregroundColor(.white.opacity(isRoot ? 1.0 : (isOLED ? 0.92 : 0.95)))
                .lineLimit(1)

            if let nip05 = profile?.nip05, !nip05.isEmpty {
                Image(systemName: "checkmark.seal.fill")
                    .font(.appSystem(size: 9))
                    .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
            }

            Text("· \(CondensedNoteLine.relativeTime(note.createdAt))")
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)

            Spacer(minLength: 4)

            if replyCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble")
                        .font(.appSystem(size: 9, weight: .medium))
                    Text("\(replyCount)")
                        .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.secondary.opacity(isOLED ? 0.6 : 0.7))
            }

            // A reply marker is noise inside a thread — the rail already says it.
            if note.isReply && depth == 0 && replyCount == 0 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.appSystem(size: 10))
                    .foregroundColor(Color.havenPurple.opacity(0.7))
            }
            if note.repostedBy != nil {
                Image(systemName: "arrow.2.squarepath")
                    .font(.appSystem(size: 10))
                    .foregroundColor(.green.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        if !displayContent.isEmpty {
            Text(NostrContentFormatter.resolveMentionsPlainText(displayContent))
                .font(.appSystem(size: bodySize))
                .foregroundColor(.white.opacity(isRoot ? 1.0 : (isOLED ? 0.8 : 0.85)))
                .lineLimit(bodyLineLimit)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var engagementRow: some View {
        if !engagement.isEmpty {
            HStack(spacing: 6) {
                if engagement.reactions > 0 {
                    countChip(
                        symbol: .emoji(engagement.topEmoji ?? "❤️"),
                        count: engagement.reactions,
                        tint: .secondary
                    )
                }
                if engagement.zaps > 0 {
                    countChip(symbol: .system("bolt.fill"), count: engagement.zaps, tint: .orange)
                }
                if engagement.reposts > 0 {
                    countChip(symbol: .system("arrow.2.squarepath"), count: engagement.reposts, tint: .green)
                }
            }
            .padding(.top, 2)
        }
    }

    private enum ChipSymbol {
        case emoji(String)
        case system(String)
    }

    private func countChip(symbol: ChipSymbol, count: Int, tint: Color) -> some View {
        HStack(spacing: 2) {
            switch symbol {
            case .emoji(let value):
                Text(value).font(.appSystem(size: 9))
            case .system(let name):
                Image(systemName: name)
                    .font(.appSystem(size: 8, weight: .bold))
                    .foregroundColor(tint)
            }
            Text("\(count)")
                .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func mediaThumbnail(_ url: URL) -> some View {
        ZStack(alignment: .bottomTrailing) {
            FeedMediaView(url: url, isThumbnail: true)
                .frame(width: isRoot ? 80 : 56, height: isRoot ? 80 : 56)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if mediaURLs.count > 1 {
                Text("+\(mediaURLs.count - 1)")
                    .font(.appSystem(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .padding(4)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var rowBackground: some View {
        switch style {
        case .card:
            RoundedRectangle(cornerRadius: 10)
                .fill(isFocused ? Color.havenPurple.opacity(isOLED ? 0.08 : 0.12) : Color.platformSecondaryGroupedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.havenPurple.opacity(0.015))
                )
        case .plain:
            // Inside a thread card the rows share one surface; only the focused
            // line is tinted, so the conversation reads as a block instead of a
            // stack of boxes.
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.havenPurple.opacity(isOLED ? 0.10 : 0.12) : Color.clear)
        }
    }

    @ViewBuilder
    private var rowBorder: some View {
        switch style {
        case .card:
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isFocused ? Color.havenPurple.opacity(isOLED ? 0.6 : 0.4) : Color.havenPurple.opacity(isOLED ? 0.30 : 0.15),
                    lineWidth: isFocused ? 1.5 : (isOLED ? 1.0 : 0.5)
                )
        case .plain:
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.havenPurple.opacity(isOLED ? 0.6 : 0.4), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Text

    private var authorPubkey: String { displayPubkey ?? note.pubkey }

    private var displayName: String {
        profile?.bestName ?? CondensedNoteLine.shortKey(authorPubkey)
    }

    private var accessibilityLabel: String {
        var parts = [displayName, CondensedNoteLine.relativeTime(note.createdAt)]
        if depth > 0 { parts.append("reply, level \(depth)") }
        if !displayContent.isEmpty {
            parts.append(NostrContentFormatter.resolveMentionsPlainText(displayContent))
        }
        if replyCount > 0 {
            parts.append("\(replyCount) \(replyCount == 1 ? "reply" : "replies")")
        }
        if !mediaURLs.isEmpty {
            parts.append(mediaURLs.count == 1 ? "1 attachment" : "\(mediaURLs.count) attachments")
        }
        return parts.joined(separator: ", ")
    }

    static func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    static func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                ? "MMM d" : "MMM d, yyyy"
            return fmt.string(from: date)
        }
    }
}

/// The card a condensed conversation sits in — one surface for the whole
/// thread, so replies read as a block instead of a stack of boxes.
struct ThreadCardBackground: ViewModifier {
    var isOLED: Bool = ConfigService.shared.config.useOLED

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                ZStack {
                    Color.platformSecondaryGroupedBackground
                    Color.havenPurple.opacity(0.015)
                }
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        Color.havenPurple.opacity(isOLED ? 0.30 : 0.15),
                        lineWidth: isOLED ? 1.0 : 0.5
                    )
            )
    }
}

extension View {
    /// Wrap a run of `CondensedNoteLine`s as a single conversation card.
    func threadCard() -> some View {
        modifier(ThreadCardBackground())
    }
}
