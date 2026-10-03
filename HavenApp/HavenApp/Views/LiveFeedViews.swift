import SwiftUI

/// One tile in the Live grid: thumbnail, a LIVE pill, and the viewer count when
/// the host publishes one.
struct LiveStreamCardView: View {
    let stream: LiveStream
    let profile: FeedProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let imageURL = stream.imageURL {
                        RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 600, height: 340))
                    } else {
                        // Half the live streams publish no image, so this is the
                        // common case, not a fallback.
                        ZStack {
                            Rectangle().fill(Color.havenPurplePale)
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.appSystem(size: 28))
                                .foregroundColor(.havenPurple.opacity(0.7))
                        }
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 6) {
                    livePill
                    if let participants = stream.participants {
                        Label("\(participants)", systemImage: "person.2.fill")
                            .font(.appSystem(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.title ?? "Untitled stream")
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(profile?.bestName ?? "npub…" + String(stream.hostPubkey.suffix(6)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var livePill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("LIVE").font(.appSystem(size: 10, weight: .bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }
}

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
    @State private var noLightningAddress = false
    @FocusState private var composerFocused: Bool

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
                FullScreenVideoPlayer(url: url, onPiPStart: { dismiss() })
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
            nostrService.fetchMissingProfiles(for: [stream.hostPubkey, stream.zapPubkey])
            chat.connect(to: stream)
        }
        .onDisappear { chat.disconnect() }
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
        .sheet(item: $zapSheet) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                sendZap(amountSats: amount)
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
        // The video has its own sound; don't play the mini player over it.
        .onAppear { MusicPlayerService.shared.pause() }
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
                }
                .menuStyle(.borderlessButton)
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
            TextField("Say something…", text: $draft)
                .textFieldStyle(.plain)
                .font(.appSystem(size: 14))
                .focused($composerFocused)
                .onSubmit { sendMessage() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.controlBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                zapSheet = ZapSheetContext(defaultAmount: max(1, configService.config.defaultZapAmount / 1000))
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.appSystem(size: 16, weight: .bold))
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zap this stream")

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

    private func listenInBackground() {
        MusicPlayerService.shared.playLive(stream: stream, item: PlayerTrack(
            id: "live:\(stream.address)",
            title: stream.title ?? "Live stream",
            artist: hostName,
            artworkURL: stream.imageURL ?? profile?.pictureURL,
            audioURL: stream.streamingURL,
            duration: nil,
            isLive: true,
            hostPubkey: stream.hostPubkey
        ))
        dismiss()
    }

    /// A stream zap pays the host named in the event, and carries the stream's
    /// address so the receipt lands in this chat rather than nowhere.
    private func sendZap(amountSats: Int) {
        guard let lud16 = lightningAddress(for: stream.zapPubkey) else {
            noLightningAddress = true
            return
        }
        let comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Task {
            do {
                try await ZapService.shared.zapNote(
                    noteId: stream.eventId,
                    notePubkey: stream.zapPubkey,
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

/// One chat row. A zap is the same row in gold with the amount in front of it —
/// same shape, so a busy chat still reads top to bottom.
struct LiveChatRowView: View {
    let message: LiveChatMessage
    let profile: FeedProfile?

    private var displayName: String {
        profile?.bestName ?? String(message.authorPubkey.prefix(8))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(url: profile?.pictureURL, pubkey: message.authorPubkey, size: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let sats = message.zapSats {
                        Text(sats > 0 ? "⚡ \(sats)" : "⚡")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                    Text(displayName)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.createdAt))))
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary)
                }

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.appSystem(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(message.isZap ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(message.isZap ? Color.orange.opacity(0.12) : Color.clear)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
