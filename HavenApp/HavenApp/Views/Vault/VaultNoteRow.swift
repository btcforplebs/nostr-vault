import SwiftUI

struct NoteRow: View {
    let event: NostrEvent
    /// When true, clamp the body to a few lines and append a "Show more"
    /// affordance. Used by compact contexts like the likes/zaps lists.
    var truncate: Bool = false
    /// Layout mode for the note display
    /// Optional inline engagement data rendered inside the card.
    var reactors: [(pubkey: String, emoji: String)]? = nil
    var latestReactionDate: Date? = nil
    var zappers: [(pubkey: String, amount: Int64)]? = nil
    var reposterPubkeys: [String]? = nil
    var quoterPubkeys: [String]? = nil
    /// Listed for another account on this device (the Vault chips): its menu
    /// would act as the active account, so there is none.
    var isOtherAccountRow: Bool = false
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
    // disagreed with the real 8-line clamp in both directions. These are the
    // rendered full heights of the note's text pieces (and of one line, at
    // `lineHeightKey`), so the button only appears when the clamp cuts text.
    @State var segmentHeights: [Int: CGFloat] = [:]
    static let lineHeightKey = -1

    /// Measured line count of each text piece, by segment index.
    var measuredLines: [Int: Int] {
        guard let line = segmentHeights[Self.lineHeightKey] else { return [:] }
        var lines: [Int: Int] = [:]
        for (i, height) in segmentHeights where i != Self.lineHeightKey {
            lines[i] = NoteClamp.lineCount(height: height, lineHeight: line, spacing: 2)
        }
        return lines
    }

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
        // Any account on this device is yours: no Report or Block on it.
        if event.pubkey == nostrService.activeHexPubkey
            || configService.allAccountHexes.contains(event.pubkey.lowercased()) {
            return .mine
        }
        if configService.whitelistedHexPubkeys.contains(event.pubkey) {
            return .whitelisted
        }
        return .tagged
    }

    var body: some View {
        expandedLayout
        .buttonStyle(.plain)
        .contextMenu {
            // Another account's row (Vault chips): Report and Block would act as
            // the active account, on a list it isn't looking at as itself.
            if noteType != .mine && !isOtherAccountRow {
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
