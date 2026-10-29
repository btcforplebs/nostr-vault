import SwiftUI
import AVFoundation

/// Player for one live stream: the video, the chat everyone else in the stream
/// is reading, and a zap button — plus the report and block affordances Apple's
/// UGC rules require on any surface showing third-party video.
struct LiveStreamPlayerView: View {
    let stream: LiveStream
    var onBlocked: ((String) -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var chat = LiveChatService()

    @State private var showingReportDialog = false
    @State private var showingBlockConfirm = false
    @State private var reportingMessage: LiveChatMessage?
    @State private var draft = ""
    @State private var zapSheet: ZapSheetContext?
    @State private var zapFailure: String?
    @AppStorage(PostButtons.storageKey) private var postButtons = ""
    @State private var noLightningAddress = false
    @FocusState private var composerFocused: Bool
    @State private var showingBlossomPicker = false
    @State private var blossomMedia: [MediaItem] = []
    @State private var isLoadingBlossomMedia = false
    /// The mini player's player, when this is the stream it has minimized —
    /// read once, as the window opens. The window shows that player's video
    /// instead of opening the stream again: a second player meant the sound
    /// stopped, reconnected and skipped on every pop-out and swipe away
    /// (Logen, 2026-10-05).
    @State private var miniPlayer: AVPlayer?

    init(stream: LiveStream, onBlocked: ((String) -> Void)? = nil) {
        self.stream = stream
        self.onBlocked = onBlocked
        let mini = MusicPlayerService.shared
        _miniPlayer = State(initialValue: mini.liveStream?.address == stream.address ? mini.livePlayer : nil)
    }

    private var profile: FeedProfile? { nostrService.profiles[stream.hostPubkey] }
    private var hostName: String {
        profile?.bestName ?? "npub…" + String(stream.hostPubkey.suffix(6))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let url = stream.streamingURL {
                // The player with picture-in-picture: starting PiP closes this
                // sheet, and the stream keeps playing in its floating window
                // while you browse the rest of the app.
                FullScreenVideoPlayer(url: url, onPiPStart: { dismiss() },
                                      sharedPlayer: miniPlayer,
                                      onSharedResume: { MusicPlayerService.shared.resume() })
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        // Minimize: the stream's sound carries on in the mini
                        // player and on the lock screen while you browse; tap
                        // Watch in the player to get the video back.
                        Button(action: listenInBackground) {
                            Image(systemName: "chevron.down")
                                .font(.appSystem(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .accessibilityLabel("Minimize")
                        .accessibilityHint("Keeps playing the sound while you browse")
                    }
                    // A 16:9 video sized to the width of a phone in landscape
                    // is taller than the screen, and a VStack that cannot fit
                    // its children pushes the last one — the composer — off the
                    // bottom. Cap the video instead; the chat takes the rest.
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .background(Color.black)
            }

            header
            Divider()
            chatColumn
        }
        // The composer is an inset rather than the last row of the stack, so it
        // is laid out against the safe area and rides above the keyboard
        // instead of being something the rest of the screen can push away.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                composer
            }
            .background(.regularMaterial)
        }
        .background(Color.platformWindowBackground)
        .onAppear {
            nostrService.fetchMissingProfiles(for: [stream.hostPubkey])
            chat.connect(to: stream)
        }
        .onDisappear {
            chat.disconnect()
            // A shared player is the mini player's, which carries on.
            if miniPlayer == nil { releaseVideo() }
        }
        .sheet(isPresented: $showingReportDialog) {
            // Reporting also blocks, which is what the existing dialog does
            // everywhere else in the app — so the stream must leave the grid.
            UGCReportingDialog(eventId: nil, pubkey: stream.hostPubkey, onDismiss: { showingReportDialog = false }) {
                showingReportDialog = false
                onBlocked?(stream.hostPubkey)
                dismiss()
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .sheet(item: $reportingMessage) { message in
            // A zap row is attributed to the payer, so report the id of the
            // event that actually carries the text — the receipt, for a zap.
            UGCReportingDialog(eventId: message.id, pubkey: message.authorPubkey,
                               onDismiss: { reportingMessage = nil }) {
                reportingMessage = nil
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .sheet(isPresented: $showingBlossomPicker) {
            BlossomMediaPickerSheet(
                blossomMedia: $blossomMedia,
                isLoading: $isLoadingBlossomMedia,
                onSelect: { item in
                    insertMedia(item)
                    showingBlossomPicker = false
                },
                onAppearLoad: { loadBlossomMedia() }
            )
            .environmentObject(configService)
        }
        .sheet(item: $zapSheet) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                sendZap(amountSats: amount)
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .smallSheetSizing()
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
        // The video has its own sound; don't play the mini player over it.
        // Sharing the mini player's, the sound is the video's and plays on.
        .onAppear {
            let mini = MusicPlayerService.shared
            if miniPlayer == nil { mini.pause() } else if !mini.isPlaying { mini.resume() }
        }
        .alert("Block this host?", isPresented: $showingBlockConfirm) {
            Button("Block", role: .destructive) {
                blockHost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their streams and posts stop appearing for you.")
        }
        .alert("No Lightning address", isPresented: $noLightningAddress) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(hostName) has not published one, so there is nowhere to send sats.")
        }
        .alert("Zap failed", isPresented: Binding(get: { zapFailure != nil }, set: { if !$0 { zapFailure = nil } })) {
            Button("OK", role: .cancel) { zapFailure = nil }
        } message: {
            Text(zapFailure ?? "")
        }
        .environment(\.liveAvatarOpensStream, false)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stream.title ?? "Untitled stream")
                .font(.appSystem(size: 16, weight: .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: stream.hostPubkey, size: 24)
                Text(hostName)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let participants = stream.participants {
                    Text("· \(participants) watching")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if let link = stream.webLink {
                        OpenInWebButton(link: link)
                        Divider()
                    }
                    Button {
                        showingReportDialog = true
                    } label: {
                        Label("Report stream", systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        showingBlockConfirm = true
                    } label: {
                        Label("Block host", systemImage: "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.appSystem(size: 16))
                        .foregroundColor(.havenPurple)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                #if os(macOS)
                // .borderlessButton flattens the label's tint on the Mac.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("More")
                #else
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Chat

    private var chatColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chat.messages.isEmpty {
                        Text("No messages yet. Say hello.")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                    }
                    ForEach(chat.messages) { message in
                        LiveChatRowView(message: message,
                                        profile: nostrService.profiles[message.authorPubkey])
                            .id(message.id)
                            .contextMenu {
                                Button {
                                    reportingMessage = message
                                } label: {
                                    Label("Report message", systemImage: "flag")
                                }
                            }
                    }
                    // Anchor: scrolling to the last message leaves its bottom
                    // edge flush with the composer, which reads as truncated.
                    Color.clear.frame(height: 1).id(Self.chatBottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            // Drag the chat down, or tap it, to put the keyboard away.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.chatBottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let chatBottomAnchor = "live-chat-bottom"

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            // Media from your relay's Blossom store, sent as its link.
            Button {
                composerFocused = false
                showingBlossomPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.appSystem(size: 17, weight: .semibold))
                    .foregroundColor(.havenPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add media from your relay")

            TextField("Say something…", text: $draft)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 14))
                .focused($composerFocused)
                .onSubmit { sendMessage() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.controlBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if PostButtons.showsZap(postButtons) {
                Button {
                    zapSheet = ZapSheetContext(defaultAmount: max(1, configService.config.defaultZapAmount / 1000))
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.appSystem(size: 16, weight: .bold))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zap this stream")
            }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.appSystem(size: 22))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? .secondary : .havenPurple)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isSending)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task {
            let sent = await chat.send(text, stream: stream)
            if !sent { draft = text }
        }
    }

    /// The picked file's link goes into the message, on its own line after
    /// anything already typed, ready to send.
    private func insertMedia(_ item: MediaItem) {
        let link = item.shareURL(with: configService).absoluteString
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? link : typed + " " + link
    }

    private func loadBlossomMedia() {
        guard !isLoadingBlossomMedia else { return }
        let relay = RelayProcessManager.shared
        guard relay.isRunning && !relay.isBooting else {
            blossomMedia = []
            return
        }
        isLoadingBlossomMedia = true
        Task {
            blossomMedia = await ComposeView.relayBlossomMedia(
                relayManager: relay, configService: configService, nostrService: nostrService)
            isLoadingBlossomMedia = false
        }
    }

    private func listenInBackground() {
        // Already the mini player's stream: it plays on as it is.
        if miniPlayer != nil { dismiss(); return }
        MusicPlayerService.shared.playLive(stream: stream, item: PlayerTrack(
            id: "live:\(stream.address)",
            title: stream.title ?? "Live stream",
            artist: hostName,
            artworkURL: stream.imageURL ?? stream.previewImageURLs.first ?? profile?.pictureURL,
            audioURL: stream.streamingURL,
            duration: nil,
            isLive: true,
            hostPubkey: stream.hostPubkey
        ))
        dismiss()
    }

    /// Stops the stream's video once its player has gone. `FullScreenVideoPlayer`
    /// only mutes on the way out, leaving the player in `VideoPlayerCache`,
    /// which suits a feed video the feed cell picks up again — but nothing
    /// picks up a live stream, so it kept downloading video, muted, until three
    /// newer videos pushed it out. That is also under the minimized audio,
    /// which is a separate player. PiP is the one owner allowed to keep it.
    private func releaseVideo() {
        guard let url = stream.streamingURL else { return }
        #if os(iOS)
        if PiPManager.shared.isPiPActive && PiPManager.shared.activeURL == url { return }
        #endif
        VideoPlayerCache.shared.removePlayer(for: url)
        VideoPlaybackService.shared.invalidateLadder(for: url)
    }

    /// A stream zap pays the host named in the event, and carries the stream's
    /// address so the receipt lands in this chat rather than nowhere.
    private func sendZap(amountSats: Int) {
        guard let lud16 = lightningAddress(for: stream.hostPubkey) else {
            noLightningAddress = true
            return
        }
        let comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Task {
            do {
                try await ZapService.shared.zapNote(
                    noteId: stream.eventId,
                    notePubkey: stream.hostPubkey,
                    lud16: lud16,
                    amountSats: amountSats,
                    message: comment.isEmpty ? "Zap from Nostr Vault" : comment,
                    addressTag: stream.address
                )
            } catch {
                zapFailure = error.localizedDescription
            }
        }
    }

    private func lightningAddress(for pubkey: String) -> String? {
        guard let profile = nostrService.profiles[pubkey] else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        return nil
    }

    /// The block list is stored as npubs and read back through a bech32 decode,
    /// so handing `blockProfile` a hex pubkey stores an entry that never
    /// matches anything. Convert first, exactly as the note row does.
    private func blockHost() {
        guard let data = Bech32.hexToData(stream.hostPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        onBlocked?(stream.hostPubkey)
        dismiss()
    }
}
