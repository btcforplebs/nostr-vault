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
    @State private var sendError: String?
    @State private var scrollPosition: String?
    @State private var useNIP04: Bool = false
    /// The photo picked for the next message, already prepared for upload.
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var attachment: PickedAttachment?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @Environment(\.dismiss) private var dismiss

    /// A photo waiting to go out with the next message. GIFs keep their bytes
    /// so they still move; everything else is re-encoded as a JPEG, which also
    /// drops the location the camera wrote into it.
    private struct PickedAttachment {
        let data: Data
        let mimeType: String
        let preview: Image?
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
                                        }
                                    )
                                    .id(message.id)
                                }

                                Spacer()
                                    .frame(height: 0)
                                    .id("bottom")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                        }
                        .onAppear {
                            scrollToBottom(proxy)
                        }
                        .onChange(of: messages.count) { _, _ in
                            scrollToBottom(proxy)
                        }
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
                            .foregroundColor(useNIP04 ? .orange.opacity(0.8) : .havenPurple.opacity(0.7))

                        Text(useNIP04 ? "NIP-04 (legacy)" : "NIP-17 (encrypted)")
                            .font(.appSystem(size: 11, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.8))

                        Spacer()

                        Button(action: { withAnimation(Motion.toggle) { useNIP04.toggle() } }) {
                            Text("Switch")
                                .font(.appSystem(size: 11, weight: .medium))
                                .foregroundColor(.havenPurple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

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

                                Button {
                                    self.attachment = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.appSystem(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                                .disabled(isSending)
                                .accessibilityLabel("Remove photo")
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }

                    // Message input
                    HStack(alignment: .bottom, spacing: 10) {
                        PhotosPicker(selection: $pickedPhotoItem, matching: .images) {
                            Image(systemName: "photo")
                                .font(.appSystem(size: 17, weight: .medium))
                                .foregroundColor(.havenPurple)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending)
                        .accessibilityLabel("Attach photo")

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
                                    .foregroundColor(.white)
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
            .navigationTitle(counterpartyProfile?.bestName ?? "DM")
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
            .onAppear {
                if messageInput.isEmpty, let initialMessage { messageInput = initialMessage }
                dmService.markRead(conversationWith: counterpartyPubkey)
                dmService.visibleConversation = counterpartyPubkey
            }
            .onDisappear {
                if dmService.visibleConversation == counterpartyPubkey {
                    dmService.visibleConversation = nil
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func attachPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            sendError = "Couldn't read that photo."
            return
        }
        let prepared: PickedAttachment?
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .gif) }) {
            prepared = PickedAttachment(data: data, mimeType: "image/gif", preview: Self.image(from: data))
        } else if let jpeg = LongFormComposeView.coverJPEG(from: data) {
            prepared = PickedAttachment(data: jpeg, mimeType: "image/jpeg", preview: Self.image(from: jpeg))
        } else {
            prepared = nil
        }
        guard let prepared else {
            sendError = "Couldn't read that photo."
            return
        }
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
            do {
                // The photo goes up first: a message that names a URL no
                // server holds would reach them as a dead link.
                var photoURL: URL?
                if let photo {
                    photoURL = try await ModePostPublisher.upload(
                        data: photo.data, mimeType: photo.mimeType,
                        configService: configService, nostrService: nostrService).url
                }
                let content = DMAttachment.content(text: messageToSend, imageURL: photoURL)
                try await dmService.sendDM(content: content, to: counterpartyPubkey, useNIP04: useNIP04)
                await MainActor.run {
                    isSending = false
                }
            } catch {
                #if DEBUG
                print("Failed to send DM: \(error)")
                #endif
                await MainActor.run {
                    isSending = false
                    messageInput = messageToSend
                    attachment = photo
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

    /// The message's photos, and its text without their links.
    private var parts: (text: String, images: [URL]) { DMAttachment.split(message.content) }

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
                    ForEach(split.images, id: \.absoluteString) { url in
                        Button {
                            onOpenImage?(url, split.images)
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

                    if !split.text.isEmpty || split.images.isEmpty {
                        Text(split.text)
                            .font(.appSystem(size: 15))
                            .foregroundColor(message.isFromMe ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .textSelection(.enabled)
                    }

                    if message.isNIP04 {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.open")
                                .font(.appSystem(size: 8, weight: .medium))
                            Text("NIP-04")
                                .font(.appSystem(size: 9, weight: .medium))
                        }
                        .foregroundColor(message.isFromMe ? .white.opacity(0.6) : .orange.opacity(0.8))
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
                .overlay(
                    Group {
                        if !message.isFromMe && ConfigService.shared.config.useOLED {
                            receivedCorners
                                .stroke(Color.platformSeparator, lineWidth: 0.8)
                        }
                    }
                )

                Text(message.timestamp.formatted(.relative(presentation: .numeric)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 6)
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
