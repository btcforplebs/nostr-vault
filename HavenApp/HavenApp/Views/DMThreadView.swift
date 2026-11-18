import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct DMThreadView: View {
    let counterpartyPubkey: String
    /// Typed into the message box on open, for the owner to edit or send —
    /// "Message seller" starts with the listing it is about.
    var initialMessage: String? = nil

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    @State private var messageInput: String = ""
    @State private var isSending: Bool = false
    /// What a long send is doing (compressing, then sending a video), shown above the message box.
    @State private var sendStage: String?
    @State private var sendError: String?
    @State private var scrollPosition: String?
    /// Whether the reader is at the bottom of the chat, and the newest message
    /// seen. A plain class in `@State`: the bottom marker writes it on every
    /// scroll frame, and that must not re-render the whole list.
    @State private var followTracker = FollowTracker()
    @State private var useNIP04: Bool = false
    /// The account this chat was opened as. A switch closes the chat and
    /// drops the draft, and Send refuses (A5, 2026-11-18).
    @State private var openedAsAccount: String?
    /// The photo picked for the next message, already prepared for upload.
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var attachment: PickedAttachment?
    /// A photo is being dragged over the conversation.
    @State private var isDropTargeted = false
    @State private var showingMediaUrl: IdentifiableURL?
    /// The other person's profile, opened from the header.
    @State private var showingProfile: IdentifiableString?
    @Namespace private var mediaZoom
    @Environment(\.dismiss) private var dismiss

    /// A photo or video waiting to go out with the next message. GIFs keep
    /// their bytes so they still move; other photos are re-encoded as a JPEG,
    /// which also drops the location the camera wrote into it. A video stays
    /// a file on disk (`video`), and the upload strips its location.
    private struct PickedAttachment {
        var data = Data()
        let mimeType: String
        let preview: Image?
        var video: DMVideoAttachment?
    }

    private var canSend: Bool {
        !isSending && (attachment != nil || !messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var conversation: DMConversation? {
        dmService.conversations.first(where: { $0.id == counterpartyPubkey })
    }

    private var messages: [DMMessage] {
        conversation?.messages ?? []
    }

    private var counterpartyProfile: FeedProfile? {
        nostrService.profiles[counterpartyPubkey]
    }

    private var hasNIP04Messages: Bool {
        conversation?.hasNIP04Messages ?? false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // NIP-04 warning banner
                if hasNIP04Messages {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.appSystem(size: 11, weight: .semibold))
                        Text("Some messages use NIP-04 (legacy encryption). New messages default to NIP-17.")
                            .font(.appSystem(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.orange.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                }

                // Messages ScrollView
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(messages) { message in
                                    MessageBubbleView(
                                        message: message,
                                        profile: counterpartyProfile,
                                        containerWidth: geometry.size.width,
                                        mediaZoom: mediaZoom,
                                        onOpenImage: { url, all in
                                            showingMediaUrl = IdentifiableURL(url: url, allURLs: all)
                                        },
                                        canRetry: dmService.canResend(message),
                                        onRetry: {
                                            Task { await dmService.resendFailed(message.id, in: counterpartyPubkey) }
                                        },
                                        onRemove: { dmService.removeFailed(message.id, in: counterpartyPubkey) }
                                    )
                                    .id(message.id)
                                }

                                Spacer()
                                    .frame(height: 0)
                                    .id("bottom")
                                    // Where the end of the list sits on screen, so a
                                    // new message only pulls you down when you are
                                    // already at the bottom (A3, 2026-11-18).
                                    .background {
                                        GeometryReader { marker in
                                            let y = marker.frame(in: .named(Self.scrollSpace)).minY
                                            Color.clear
                                                .onAppear { followTracker.update(markerY: y, visibleHeight: geometry.size.height) }
                                                .onChange(of: y) { _, newY in
                                                    followTracker.update(markerY: newY, visibleHeight: geometry.size.height)
                                                }
                                        }
                                    }
                                    .onDisappear { followTracker.isNearBottom = false }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .onAppear {
                            followTracker.newestID = messages.last?.id
                            scrollToBottom(proxy)
                        }
                        .onChange(of: messages.count) { _, _ in
                            let newest = messages.last
                            let follow = DMThreadFollow.shouldFollow(
                                wasNearBottom: followTracker.isNearBottom,
                                previousNewestID: followTracker.newestID,
                                newestID: newest?.id,
                                newestIsFromMe: newest?.isFromMe ?? false
                            )
                            followTracker.newestID = newest?.id
                            if follow { scrollToBottom(proxy) }
                        }
                    }
                }
                .overlay {
                    if messages.isEmpty {
                        Text("Start a conversation")
                            .font(.appSystem(size: 15))
                            .foregroundColor(.secondary)
                    }
                }

                // Input Area
                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.5)

                    // Protocol selector (compact inline)
                    HStack(spacing: 6) {
                        Image(systemName: useNIP04 ? "lock.open" : "lock.fill")
                            .font(.appSystem(size: 10, weight: .medium))
                            .foregroundColor(useNIP04 ? .orange.opacity(0.8) : .accentText.opacity(0.7))

                        Text(useNIP04 ? "NIP-04 (legacy)" : "NIP-17 (encrypted)")
                            .font(.appSystem(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.8))

                        Spacer()

                        Button(action: { withAnimation(Motion.toggle) { useNIP04.toggle() } }) {
                            Text("Switch")
                                .font(.appSystem(size: 11, weight: .medium))
                                .foregroundColor(.accentText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    if let sendStage {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(sendStage).font(.appSystem(size: 13)).foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                        .accessibilityElement(children: .combine)
                    }

                    if let attachment {
                        HStack {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let preview = attachment.preview {
                                        preview.resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.2)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    if attachment.video != nil {
                                        Image(systemName: "play.circle.fill")
                                            .font(.appSystem(size: 22))
                                            .foregroundStyle(.white, .black.opacity(0.4))
                                    }
                                }

                                Button {
                                    discardAttachment()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.appSystem(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .disabled(isSending)
                                .accessibilityLabel(attachment.video == nil ? "Remove photo" : "Remove video")
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }

                    // Message input
                    HStack(alignment: .bottom, spacing: 10) {
                        // Photos and videos from one button (Logen 2026-11-06).
                        PhotosPicker(selection: $pickedPhotoItem, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "photo")
                                .font(.appSystem(size: 17, weight: .medium))
                                .foregroundColor(.accentText)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)
                        .accessibilityLabel("Attach photo or video")
                        #if os(iOS)
                        // A photo copied in another app, without a keyboard for ⌘V:
                        // press and hold (or right-click) the photo button.
                        .contextMenu {
                            Button {
                                pasteClipboardImage()
                            } label: {
                                Label("Paste Photo", systemImage: "doc.on.clipboard")
                            }
                            .disabled(isSending)
                        }
                        #endif

                        TextField("Message...", text: $messageInput, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .font(.appSystem(size: 15))
                            #if os(macOS)
                            // Return sends, the way every desktop chat client does.
                            // Nothing is lost by taking the key: a vertical-axis
                            // TextField on macOS ignores plain Return anyway — Option
                            // + Return is what inserts a newline, and still does.
                            .onSubmit { sendMessage() }
                            #endif
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.platformSecondaryGroupedBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22)
                                    .stroke(Color.borderStrong, lineWidth: 1)
                            )

                        Button(action: sendMessage) {
                            if isSending {
                                ProgressView()
                                    .frame(width: 34, height: 34)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.appSystem(size: 15, weight: .bold))
                                    .foregroundColor(.onAccent)
                                    .frame(width: 34, height: 34)
                                    .background(canSend ? Color.havenPurple : Color.secondary.opacity(0.25))
                                    .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 4)
                }
                #if os(macOS)
                .background(Color(nsColor: .controlBackgroundColor))
                #else
                .background(Color.platformWindowBackground)
                #endif
            }
            .background(Color.platformWindowBackground.ignoresSafeArea())
            // A photo or video dragged in from Photos, Files or Safari goes out
            // with the next message, the same as one picked with the button.
            .onDrop(of: DroppedMedia.acceptedTypes, isTargeted: $isDropTargeted) { providers in
                guard !isSending, let provider = providers.first else { return false }
                Task { await attachDropped(provider) }
                return true
            }
            .dropTargetHighlight(isDropTargeted, cornerRadius: 0)
            #if os(iOS)
            .modifier(PastesClipboardImage(action: pasteClipboardImage))
            #endif
            .navigationTitle(counterpartyProfile?.bestName ?? "DM")
            .toolbar {
                // Who this is, and a way to their profile (Android DMThreadScreen).
                ToolbarItem(placement: .principal) {
                    Button { showingProfile = IdentifiableString(id: counterpartyPubkey) } label: {
                        HStack(spacing: 8) {
                            AvatarView(url: counterpartyProfile?.pictureURL, pubkey: counterpartyPubkey, size: 28)
                            Text(counterpartyProfile?.bestName ?? String(counterpartyPubkey.prefix(8)) + "…")
                                .font(.appSystem(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their profile")
                }
            }
            .sheet(item: $showingProfile) { p in
                ProfileView(pubkey: p.id, onDismiss: { showingProfile = nil })
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            // Presented as a sheet from the profile, where there is no title bar and no
            // swipe-down: Escape or this button is the only way back out. Pushed from the
            // inbox, the same dismiss pops the thread.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "dm.inbox.close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            #endif
            .alert("Failed to Send", isPresented: Binding<Bool>(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )) {
                Button("OK") { sendError = nil }
            } message: {
                if let sendError = sendError {
                    Text(sendError)
                }
            }
            .onChange(of: pickedPhotoItem) { _, item in
                guard let item else { return }
                pickedPhotoItem = nil
                Task { await attachPhoto(item) }
            }
            .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
            .onChange(of: configService.activeAccountHexPubkey) { _, active in
                guard DMChatAccountGuard.mustClose(openedAs: openedAsAccount, active: active) else { return }
                messageInput = ""
                discardAttachment()
                dismiss()
            }
            .onAppear {
                if openedAsAccount == nil { openedAsAccount = configService.activeAccountHexPubkey }
                if messageInput.isEmpty, let initialMessage { messageInput = initialMessage }
                dmService.markRead(conversationWith: counterpartyPubkey)
                dmService.visibleConversation = counterpartyPubkey
            }
            .onDisappear {
                if dmService.visibleConversation == counterpartyPubkey {
                    dmService.visibleConversation = nil
                }
            }
            // A message that came while the app was away counts until you are
            // back on this thread (DMUnreadRule); back, it is read here.
            .onReceive(NotificationCenter.default.publisher(for: Self.becameActive)) { _ in
                if dmService.visibleConversation == counterpartyPubkey, (conversation?.unreadCount ?? 0) > 0 {
                    dmService.markRead(conversationWith: counterpartyPubkey)
                }
            }
        }
    }

    #if os(iOS)
    private static let becameActive = UIApplication.didBecomeActiveNotification
    #else
    private static let becameActive = NSApplication.didBecomeActiveNotification
    #endif

    private static let scrollSpace = "dmThreadScroll"

    private final class FollowTracker {
        /// Starts true: a chat opens at the bottom.
        var isNearBottom = true
        var newestID: String?

        func update(markerY: CGFloat, visibleHeight: CGFloat) {
            isNearBottom = DMThreadFollow.isNearBottom(bottomMarkerY: markerY, visibleHeight: visibleHeight)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Heading to the bottom: a message landing mid-scroll still follows.
        followTracker.isNearBottom = true
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func attachPhoto(_ item: PhotosPickerItem) async {
        if DMVideoAttachment.isVideo(item) {
            guard let video = await DMVideoAttachment.load(item) else {
                sendError = "Couldn't read that video."
                return
            }
            await attachVideo(video)
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            sendError = "Couldn't read that photo."
            return
        }
        prepareAttachment(data, isGIF: item.supportedContentTypes.contains(where: { $0.conforms(to: .gif) }))
    }

    @MainActor
    private func attachDropped(_ provider: NSItemProvider) async {
        switch await DroppedMedia.load(provider, acceptingVideo: true) {
        case .image(let data, let type)?:
            prepareAttachment(data, isGIF: type.conforms(to: .gif))
        case .video(let file, let type)?:
            await attachVideo(DMVideoAttachment(file: file, type: type))
        case nil:
            sendError = "Couldn't read that photo or video."
        }
    }

    @MainActor
    private func attachVideo(_ video: DMVideoAttachment) async {
        let poster = await video.poster()
        discardAttachment()
        attachment = PickedAttachment(mimeType: video.mimeType, preview: poster, video: video)
    }

    /// Removes the attachment, and a video's copy on disk with it.
    @MainActor
    private func discardAttachment() {
        attachment?.video?.discard()
        attachment = nil
    }

    private func pasteClipboardImage() {
        guard !isSending else { return }
        guard let data = PlatformClipboard.getImageData() else {
            sendError = "There's no photo on the clipboard."
            return
        }
        // getImageData hands a GIF back in its own bytes; its header says so.
        let isGIF = data.prefix(3) == Data("GIF".utf8)
        prepareAttachment(data, isGIF: isGIF)
    }

    @MainActor
    private func prepareAttachment(_ data: Data, isGIF: Bool) {
        // As the web's preparePhoto: at most 50 MB, a GIF told by its own header (a JPEG named .gif is redrawn),
        // and a GIF keeps its frames with every comment, XMP, ICC and app block stripped (GIFStrip).
        guard data.count <= 50 * 1024 * 1024 else {
            sendError = "That photo is too big to send (at most 50 MB)."
            return
        }
        let prepared: PickedAttachment?
        if GIFStrip.isGIF(data) {
            prepared = (try? GIFStrip.strip(data)).map { PickedAttachment(data: $0, mimeType: "image/gif", preview: Self.image(from: $0)) }
        } else if let jpeg = LongFormComposeView.coverJPEG(from: data) {
            prepared = PickedAttachment(data: jpeg, mimeType: "image/jpeg", preview: Self.image(from: jpeg))
        } else {
            prepared = nil
        }
        guard let prepared else {
            sendError = "Couldn't read that photo."
            return
        }
        discardAttachment()
        attachment = prepared
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    private func sendMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = attachment
        guard !trimmed.isEmpty || photo != nil, !isSending else { return }
        guard DMChatAccountGuard.maySend(openedAs: openedAsAccount,
                                         active: configService.activeAccountHexPubkey) else {
            sendError = "You switched account. Open the chat again to send from this one."
            return
        }

        isSending = true
        let messageToSend = trimmed
        messageInput = ""
        attachment = nil
        #if os(iOS)
        // Tapping send while the keyboard holds an uncommitted word (an inline
        // prediction or autocorrect suggestion) makes UIKit commit it after the
        // clear above, which writes the sent text back into the field. Clear
        // again once that commit has landed, unless it's new typing.
        DispatchQueue.main.async {
            let leftover = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty && messageToSend.contains(leftover) {
                messageInput = ""
            }
        }
        #endif

        Task {
            // Set once a locked photo's words went out on their own: a failure after that gives back only the photo.
            var wordsSent = false
            do {
                // The photo or video goes up first: a message that names a
                // URL no server holds would reach them as a dead link.
                var mediaURL: URL?
                if let video = photo?.video, !useNIP04 {
                    // A NIP-17 video goes locked like a photo (DMFile, kind 15): compressed with the feed's export,
                    // then encrypted here; only ciphertext is uploaded, the key travels inside the sealed message.
                    await MainActor.run { sendStage = "Compressing video…" }
                    let clip = try await video.compressed()
                    defer { try? FileManager.default.removeItem(at: clip) }
                    let size = (try? FileManager.default.attributesOfItem(atPath: clip.path))?[.size] as? Int ?? 0
                    guard DMFile.videoFits(byteCount: size) else { throw DMFileTransfer.TransferError.videoTooLarge(size) }
                    let plain = try Data(contentsOf: clip)
                    await MainActor.run { sendStage = "Sending video (\(DMFileTransfer.megabytes(plain.count)))…" }
                    // Up to 100 MB: sealed and hashed off the main thread so the thread keeps scrolling.
                    let enc = try await Task.detached(priority: .userInitiated) { try DMFile.encrypt(plain) }.value
                    let url = try await DMFileTransfer.upload(enc, configService: configService, nostrService: nostrService)
                    DMFileTransfer.keep(plain, for: DMFile.Sealed(url: url, key: enc.key, nonce: enc.nonce, x: enc.x,
                                                                  ox: enc.ox, mime: "video/mp4"))
                    if !messageToSend.isEmpty {
                        try await dmService.sendDM(content: messageToSend, to: counterpartyPubkey)
                        wordsSent = true
                    }
                    try await dmService.sendDMFile(url: url, encrypted: enc, mime: "video/mp4",
                                                   to: counterpartyPubkey, after: wordsSent)
                    await MainActor.run {
                        isSending = false
                        sendStage = nil
                        video.discard()
                    }
                    return
                } else if let video = photo?.video {
                    // NIP-04 has no file message: the video stays a link, as before.
                    let url = try await ModePostPublisher.upload(
                        fileURL: video.file, mimeType: video.mimeType,
                        configService: configService, nostrService: nostrService).url
                    mediaURL = DMAttachment.videoLink(url, extension: video.fileExtension)
                } else if let photo, !useNIP04 {
                    // A NIP-17 photo goes locked (DMFile, kind 15): encrypted here, only ciphertext uploaded, the
                    // key inside the sealed message. Its words, if any, go first as their own message, as the web.
                    let enc = try DMFile.encrypt(photo.data)
                    let url = try await DMFileTransfer.upload(enc, configService: configService, nostrService: nostrService)
                    DMFileTransfer.keep(photo.data, for: DMFile.Sealed(url: url, key: enc.key, nonce: enc.nonce, x: enc.x,
                                                                       ox: enc.ox, mime: photo.mimeType))
                    if !messageToSend.isEmpty {
                        try await dmService.sendDM(content: messageToSend, to: counterpartyPubkey)
                        wordsSent = true
                    }
                    try await dmService.sendDMFile(url: url, encrypted: enc, mime: photo.mimeType,
                                                   to: counterpartyPubkey, after: wordsSent)
                    await MainActor.run { isSending = false }
                    return
                } else if let photo {
                    // NIP-04 has no file message: the photo stays a link, as before.
                    mediaURL = try await ModePostPublisher.upload(
                        data: photo.data, mimeType: photo.mimeType,
                        configService: configService, nostrService: nostrService).url
                }
                let content = DMAttachment.content(text: messageToSend, mediaURL: mediaURL)
                try await dmService.sendDM(content: content, to: counterpartyPubkey, useNIP04: useNIP04)
                await MainActor.run {
                    isSending = false
                    photo?.video?.discard()
                }
            } catch {
                #if DEBUG
                print("Failed to send DM: \(error)")
                #endif
                let sentWords = wordsSent
                await MainActor.run {
                    isSending = false
                    sendStage = nil
                    if !sentWords { messageInput = messageToSend }
                    if attachment == nil { attachment = photo } else { photo?.video?.discard() }
                    sendError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: DMMessage
    let profile: FeedProfile?
    var containerWidth: CGFloat = 360
    var mediaZoom: Namespace.ID? = nil
    /// Opens a photo the message carries; the second argument is all of them.
    var onOpenImage: ((URL, [URL]) -> Void)? = nil
    /// Not sent: whether Try again is offered, and what Try again / Remove do (DMSendStatusLine).
    var canRetry: Bool = false
    var onRetry: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    /// The text with its links marked; on a sent (purple) bubble they are
    /// underlined white rather than tinted, so they still read as links.
    static func linked(_ text: String, fromMe: Bool) -> AttributedString {
        var out = ProfileBioLinks.attributed(text)
        guard fromMe else { return out }
        for run in out.runs where run.link != nil {
            out[run.range].underlineStyle = .single
        }
        return out
    }

    /// The message's photos and videos, and its text without their links.
    private var parts: (text: String, images: [URL], videos: [URL]) { DMAttachment.split(message.content, withVideos: true) }

    private var sentCorners: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18
        )
    }

    private var receivedCorners: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isFromMe {
                Spacer(minLength: 60)
            } else {
                if let profile = profile {
                    AvatarView(url: profile.pictureURL, pubkey: message.senderPubkey, size: 28)
                        .clipShape(Circle())
                        .padding(.trailing, 8)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 28, height: 28)
                        .padding(.trailing, 8)
                }
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 0) {
                    let split = parts
                    // Locked photos and videos (DMFile) open from their decrypted copy; the swipe list holds only plain links.
                    let openable = (split.images + split.videos).filter { DMFile.parseLink($0.absoluteString) == nil }
                    ForEach(split.images, id: \.absoluteString) { url in
                        if let sealed = DMFile.parseLink(url.absoluteString) {
                            LockedDMPhotoTile(sealed: sealed, size: min(240, containerWidth * 0.6), mediaZoom: mediaZoom) { local in
                                onOpenImage?(local, [local])
                            }
                        } else {
                        Button {
                            onOpenImage?(url, openable)
                        } label: {
                            RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 600, height: 600))
                                .frame(width: min(240, containerWidth * 0.6), height: min(240, containerWidth * 0.6))
                                .clipped()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(url, namespace: mediaZoom)
                        .accessibilityLabel("Photo")
                        }
                    }
                    ForEach(split.videos, id: \.absoluteString) { url in
                        if let sealed = DMFile.parseLink(url.absoluteString) {
                            LockedDMVideoTile(sealed: sealed, size: min(240, containerWidth * 0.6), mediaZoom: mediaZoom) { local in
                                onOpenImage?(local, [local])
                            }
                        } else {
                        Button {
                            onOpenImage?(url, openable)
                        } label: {
                            DMVideoTile(url: url, size: min(240, containerWidth * 0.6))
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(url, namespace: mediaZoom)
                        }
                    }

                    if !split.text.isEmpty || (split.images.isEmpty && split.videos.isEmpty) {
                        // Links found as in a bio (no markdown read), and a tap
                        // opens the in-app browser by the post-link rules.
                        Text(Self.linked(split.text, fromMe: message.isFromMe))
                            .font(.appSystem(size: 15))
                            .foregroundColor(message.isFromMe ? .onAccent : .primary)
                            .tint(message.isFromMe ? Color.onAccent : .havenPurple)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { InAppBrowser.route($0) })
                    }

                    if message.isNIP04 {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.open")
                                .font(.appSystem(size: 8, weight: .medium))
                            Text("NIP-04")
                                .font(.appSystem(size: 9, weight: .medium))
                        }
                        .foregroundColor(message.isFromMe ? .onAccent.opacity(0.6) : .orange.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.top, split.text.isEmpty ? 8 : 0)
                        .padding(.bottom, 8)
                    }
                }
                .background(
                    Group {
                        if message.isFromMe {
                            LinearGradient(
                                colors: [.havenPurple, .havenPurpleDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else {
                            Color.platformSecondaryGroupedBackground
                        }
                    }
                )
                .clipShape(message.isFromMe ? AnyShape(sentCorners) : AnyShape(receivedCorners))
                // Not out yet (or not at all): the bubble reads as not sent.
                .opacity(message.sendState == nil ? 1 : 0.6)
                .overlay(
                    Group {
                        if !message.isFromMe && ConfigService.shared.config.useOLED {
                            receivedCorners
                                .stroke(Color.platformSeparator, lineWidth: 0.8)
                        }
                    }
                )

                DMSendStatusLine(message: message, canRetry: canRetry, onRetry: onRetry, onRemove: onRemove)
            }
            .frame(maxWidth: containerWidth * 0.75, alignment: message.isFromMe ? .trailing : .leading)

            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
    }
}

// MARK: - Preview

#Preview {
    DMThreadView(counterpartyPubkey: "recipient_pubkey")
        .environmentObject(NostrService.shared)
        .environmentObject(ConfigService.shared)
}
