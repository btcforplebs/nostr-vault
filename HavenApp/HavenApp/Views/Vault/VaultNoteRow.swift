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
    @State var isHovered = false
    @State private var showingReportDialog = false
    @State private var showingBlockConfirm = false
    @State var showingReactors = false
    @State var showingReposters = false
    @State var showingQuoters = false
    @State var isExpanded = false
    // "Show more" used to key off `cleanContent.count > 240` — a proxy that
    // disagreed with the real 8-line clamp in both directions: a short note
    // with several newlines could wrap past 8 lines with no button, and a
    // long one-paragraph note under the char threshold... no, over it but
    // still fitting in 8 lines got a button that revealed nothing new.
    // These track the note's actual rendered height clamped vs. unclamped,
    // so the button only appears when the clamp is actually cutting text.
    @State var clampedContentHeight: CGFloat = 0
    @State var fullContentHeight: CGFloat = 0
    var isContentClamped: Bool { fullContentHeight > clampedContentHeight + 1 }

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
                    showingBlockConfirm = true
                }) {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
            }
        }
        .confirmBlockUser(isPresented: $showingBlockConfirm) {
            blockUser(hexPubkey: event.pubkey)
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

                    if event.isFromNostrVault {
                        NostrVaultBadge(size: 10)
                    }

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
                        .meshMediaNote(author: event.pubkey, tags: event.tags)
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
                Color.white.opacity(isHovered ? 0.04 : 0)
            }
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                // Matches the feed's compact row and the note-detail parent card.
                // This was pinned to the non-OLED values while every other post
                // surface doubled its accent outline against black, leaving the
                // Relay tab visibly fainter than the rest of the app.
                .stroke(
                    Color.havenPurple.opacity(configService.config.useOLED ? 0.30 : 0.15),
                    lineWidth: configService.config.useOLED ? 1.0 : 0.5
                )
        )
        .contentShape(Rectangle())
        .animation(Motion.control, value: isHovered)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .onHover { isHovered = $0 }
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

}
