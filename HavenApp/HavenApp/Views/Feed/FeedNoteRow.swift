import SwiftUI

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    let rowData: FeedNoteRowData
    var onReply: (() -> Void)? = nil
    var onQuote: (() -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL, [URL]) -> Void)? = nil
    var showParent: Bool = true
    var isReplyToNext: Bool = false
    /// `.wide` everywhere (Logen): avatar and name on one line, text and
    /// media full width under it, so an expanded post looks the same in the
    /// feed, threaded cards and the thread view, and gets the most room.
    var layoutMode: NoteLayoutMode = .wide
    var isFocused: Bool = false
    var suppressCardStyling: Bool = false
    /// Lets a caller shrink the avatar without touching anything else about
    /// the full layout — used when this row opens in place inside a thread
    /// card, where the rail and indent already eat into the width a plain
    /// feed row gets for free.
    var avatarSize: CGFloat = 40

    // Zero ObservableObject subscriptions — all data comes via rowData/actions
    @Environment(\.feedActions) var actions
    /// The openURL of the screen around this row: the row overrides it for
    /// its own subtree, and hands hashtag links back up to it.
    @Environment(\.openURL) private var inheritedOpenURL

    @State var showingEmojiPicker = false
    @State var showingTapbackPopover = false
    @State var reactionButtonFrame: CGRect = .zero
    @GestureState var holdingReaction = false
    @State var showLightning = false
    @AppStorage(PostButtons.storageKey) var postButtons = ""
    @State var zapBoltAnchor = ZapFlightAnchor()
    @State var zapSheetContext: ZapSheetContext?
    @State var showingDeleteConfirm = false
    @State var showingBroadcastSheet = false
    @State var showingTrustWeb = false
    /// Whose web the globe opens on: the post's author or, from the reply
    /// header's avatar, the parent's.
    @State var trustWebPubkey = ""
    @State var showingReportSheet = false
    @State var showingBlockConfirm = false
    @State var showingNoteIdInRow: String?
    @State var noLightningAddressAlert = false
    @State var showingUserMenu = false
    @State var menuExpanded = false
    @State var showingParentUserMenu = false
    @State var parentMenuExpanded = false
    @State var repostPulse = false
    @State var likePulse = false
    @State var zapPulse = false
    @State var parentFetchStartedAt: Date? = nil
    @State var parentFetchFailed = false
    @State var parentSkeletonShimmer = false
    @State var quoteFetchStarted: Set<String> = []
    @State var quoteFetchFailed: Set<String> = []

    var useCompactMode: Bool = false // Whether compact mode is active for this feed type
    var isExpanded: Bool = false // Whether this specific note is expanded
    var onTapRow: (() -> Void)? = nil

    var body: some View {
        Group {
            if useCompactMode {
                // Compact mode is active for this feed - show compact or expanded based on state
                if isExpanded {
                    fullLayout
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity
                        ))
                } else {
                    compactLayout
                        .transition(.opacity)
                }
            } else {
                // Compact mode not active - always show full layout
                fullLayout
            }
        }
        .animation(Motion.panel, value: isExpanded)
        .onAppear {
            // Fetch referenced notes only when this row becomes visible (lazy).
            if note.isReply, let parentId = note.parentEventId, rowData.parentNote == nil {
                actions.fetchMissingNote(parentId)
            }
            if note.kind == 6, note.content.isEmpty,
               let refId = note.repostedEventId, rowData.resolvedOriginal == nil {
                actions.fetchMissingNote(refId)
            }
            for qId in note.quotedEventIds where actions.findNote(qId) == nil {
                actions.fetchMissingNote(qId)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "nostr" {
                let identifier = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                if identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1") {
                    if let pubkey = QuoteReference.profilePubkey(fromBech32: identifier) {
                        onProfile?(pubkey)
                    }
                    return .handled
                }
                if identifier.hasPrefix("note1") || identifier.hasPrefix("nevent1") || identifier.hasPrefix("naddr1") {
                    showingNoteIdInRow = identifier
                    return .handled
                }
            }
            // A #hashtag goes up to the screen that presents hashtag feeds.
            if HashtagLink.tag(from: url) != nil {
                inheritedOpenURL(url)
                return .handled
            }
            return .systemAction
        })
        // One sheet and one alert for the row, not a presenter per kind:
        // every row in the feed built all of them, part of the stall when
        // the feed first draws (Time Profiler, build 36).
        // Outside the row's openURL, as the broadcast, note and report sheets
        // were: a link inside a sheet is the sheet's, not the row's.
        .sheet(item: rowSheet) { sheet in sheetContent(sheet) }
        .trustWebPresentation(isPresented: $showingTrustWeb, author: trustWebPubkey)
        .alert(rowAlert?.title ?? "", isPresented: rowAlertShown, presenting: rowAlert) { alert in
            alertActions(alert)
        } message: { alert in
            Text(alert.message)
        }
        .contextMenu {
            if rowData.isOwnNote {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            }
        }
        .onDisappear { showingUserMenu = false; menuExpanded = false; showingParentUserMenu = false; parentMenuExpanded = false }
    }

}

// MARK: - Sheets and alerts

extension FeedNoteRow {
    /// The row's one sheet. The flags stay as they were, set all over the
    /// row; this reads whichever is up.
    enum RowSheet: Identifiable {
        case zap(ZapSheetContext)
        case broadcast
        case note(String)
        case report

        var id: String {
            switch self {
            case .zap(let context): "zap-\(context.id)"
            case .broadcast: "broadcast"
            case .note(let id): "note-\(id)"
            case .report: "report"
            }
        }
    }

    /// The row's one alert.
    enum RowAlert {
        case noLightningAddress, delete, block

        var title: String {
            switch self {
            case .noLightningAddress: "No Lightning Address"
            case .delete: "Delete Post"
            case .block: "Block User"
            }
        }

        var message: String {
            switch self {
            case .noLightningAddress: "This user hasn't configured a lightning address, so they can't receive zaps."
            case .delete: "Request deletion of this post? Not all relays honor NIP-09 deletion requests."
            case .block: "Block this user? Their posts will be hidden from your feed."
            }
        }
    }

    var rowSheet: Binding<RowSheet?> {
        Binding(
            get: {
                if let context = zapSheetContext { return .zap(context) }
                if showingBroadcastSheet { return .broadcast }
                if let id = showingNoteIdInRow { return .note(id) }
                if showingReportSheet { return .report }
                return nil
            },
            set: { sheet in
                guard sheet == nil else { return }
                zapSheetContext = nil
                showingBroadcastSheet = false
                showingNoteIdInRow = nil
                showingReportSheet = false
            }
        )
    }

    var rowAlert: RowAlert? {
        if noLightningAddressAlert { return .noLightningAddress }
        if showingDeleteConfirm { return .delete }
        if showingBlockConfirm { return .block }
        return nil
    }

    var rowAlertShown: Binding<Bool> {
        Binding(
            get: { rowAlert != nil },
            set: { shown in
                guard !shown else { return }
                noLightningAddressAlert = false
                showingDeleteConfirm = false
                showingBlockConfirm = false
            }
        )
    }

    @ViewBuilder
    func sheetContent(_ sheet: RowSheet) -> some View {
        switch sheet {
        case .zap(let context):
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                if let lud16 = actions.getLightningAddress(zapRecipient) {
                    Task {
                        let sent = await actions.zapNote(note, lud16, amount)
                        if sent { Motion.firePulse($zapPulse) }
                    }
                    // Same strike as a tap, once the amount sheet has slid
                    // away — launched under it, the bolt would cross a
                    // screen the sheet still covers.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if !ZapFlightCoordinator.shared.launch(to: zapBoltAnchor, onArrive: { showLightning = true }) {
                            showLightning = true
                        }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .smallSheetSizing()
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        case .broadcast:
            EventBroadcastSheet(note: note)
        case .note(let id):
            NoteDetailViewWrapper(noteId: id, onDismiss: { showingNoteIdInRow = nil })
        case .report:
            UGCReportingDialog(eventId: bodySource.id, pubkey: bodySource.pubkey, onDismiss: { showingReportSheet = false }) { }
        }
    }

    @ViewBuilder
    func alertActions(_ alert: RowAlert) -> some View {
        switch alert {
        case .noLightningAddress:
            Button("OK", role: .cancel) { }
        case .delete:
            Button("Delete", role: .destructive) {
                actions.deleteNote(note.id)
            }
            Button("Cancel", role: .cancel) { }
        case .block:
            Button("Block", role: .destructive) {
                actions.blockUser(rowData.displayPubkey)
                ActionToastManager.shared.show(
                    icon: "hand.raised.fill",
                    message: "Blocked \(rowData.displayProfile?.bestName ?? "user")",
                    tone: .neutral
                )
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

// FeedMediaThumbnail has been replaced by FeedMediaView (see Components/FeedMediaView.swift)
