import SwiftUI

/// The sheets the live player opens beyond reporting and zapping.
enum LivePlayerSheet: Identifiable {
    /// The note composer, filled with the stream's announcement.
    case shareNote(String)
    case shareProfile(String)
    case profile(String)
    case media(URL)

    var id: String {
        switch self {
        case .shareNote: return "share-note"
        case .shareProfile(let pubkey): return "share-profile-\(pubkey)"
        case .profile(let pubkey): return "profile-\(pubkey)"
        case .media(let url): return "media-\(url.absoluteString)"
        }
    }
}

extension LiveStreamPlayerView {
    // MARK: - Video controls

    /// Minimize, or in full screen the way back out of it.
    @ViewBuilder
    var videoControlsLeading: some View {
        Group {
            if isFullScreen {
                LiveVideoOverlayButton(systemImage: "arrow.down.right.and.arrow.up.left",
                                       label: "Exit full screen") { setFullScreen(false) }
            } else {
                // Minimize: the stream's sound carries on in the mini player
                // and on the lock screen while you browse; tap Watch in the
                // player to get the video back.
                LiveVideoOverlayButton(systemImage: "chevron.down", label: "Minimize",
                                       action: listenInBackground)
                    .accessibilityHint("Keeps playing the sound while you browse")
            }
        }
        .padding(6)
    }

    /// Full screen, or in full screen the chat on and off.
    @ViewBuilder
    var videoControlsTrailing: some View {
        Group {
            if isFullScreen {
                LiveVideoOverlayButton(systemImage: "bubble.left.and.bubble.right.fill",
                                       label: showsChatOverlay ? "Hide chat" : "Show chat",
                                       isOn: showsChatOverlay) {
                    withAnimation(Motion.fade) { showsChatOverlay.toggle() }
                }
                // The chat sits on the right; its button moves to its left
                // edge so the two never overlap.
                .padding(.trailing, showsChatOverlay ? chatOverlayWidth : 0)
            } else {
                LiveVideoOverlayButton(systemImage: "arrow.up.left.and.arrow.down.right",
                                       label: "Full screen") { setFullScreen(true) }
            }
        }
        .padding(6)
    }

    func setFullScreen(_ on: Bool) {
        composerFocused = false
        if on { LiveFullScreen.enter() } else { LiveFullScreen.exit() }
        withAnimation(Motion.fade) {
            isFullScreen = on
            if !on { showsChatOverlay = false }
        }
    }

    // MARK: - Chat over the video

    var chatOverlayWidth: CGFloat { 340 }

    /// The chat and its composer down the right of a full-screen video, dark
    /// and see-through so the picture still reads behind it.
    var chatOverlay: some View {
        VStack(spacing: 0) {
            chatColumn
            Divider()
            composer
        }
        .frame(width: chatOverlayWidth)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.35))
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: - Chat rows

    @ViewBuilder
    func chatRowMenu(_ message: LiveChatMessage) -> some View {
        let name = nostrService.profiles[message.authorPubkey]?.bestName ?? "this person"
        Button { sheet = .profile(message.authorPubkey) } label: {
            Label("View \(name)'s profile", systemImage: "person.crop.circle")
        }
        if message.authorPubkey != configService.activeAccountHexPubkey {
            Button { mutingMessage = message } label: {
                Label("Mute \(name)", systemImage: "speaker.slash")
            }
        }
        Button { reportingMessage = message } label: {
            Label("Report message", systemImage: "flag")
        }
    }

    var muteTitle: String {
        guard let pubkey = mutingMessage?.authorPubkey,
              let name = nostrService.profiles[pubkey]?.bestName else { return "Mute this person?" }
        return "Mute \(name)?"
    }

    /// The app's mute: the block list, stored as npubs (see `blockHost`).
    /// Their rows leave this chat at once.
    func mute(_ pubkey: String) {
        guard let data = Bech32.hexToData(pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        chat.hide(authorPubkey: pubkey)
        ActionToastManager.shared.show(icon: "speaker.slash", message: "Muted")
    }

    // MARK: - Sharing

    /// The note "Share as a note" opens the composer with: the owner reads it
    /// and posts it themselves.
    var shareNoteText: String {
        LiveStreamShare.noteText(
            title: stream.title,
            hostName: hostName,
            pictureURL: stream.imageURL ?? stream.previewImageURLs.first,
            streamingURL: stream.streamingURL,
            naddr: LiveStreamShare.naddr(authorPubkey: stream.authorPubkey, identifier: stream.identifier,
                                         relays: stream.chatRelays))
    }

    @ViewBuilder
    func sheetContent(_ item: LivePlayerSheet) -> some View {
        switch item {
        case .shareNote(let text):
            ComposeView(onDismiss: { sheet = nil }, replyTo: nil, quoteTo: nil,
                        initialContent: text, restoredDraftId: nil)
                .environmentObject(nostrService)
                .environmentObject(configService)
                .environmentObject(RelayProcessManager.shared)
        case .shareProfile(let pubkey):
            ShareProfileSheet(pubkey: pubkey)
        case .profile(let pubkey):
            ProfileView(pubkey: pubkey, onDismiss: { sheet = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        case .media(let url):
            FeedMediaViewer(url: url, onDismiss: { sheet = nil })
                .environmentObject(configService)
        }
    }
}
