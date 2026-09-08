import SwiftUI

struct GroupChatView: View {
    let identifier: GroupIdentifier

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared

    @State private var messageInput: String = ""
    @State private var isSending: Bool = false
    @State private var sendError: String?
    @State private var showingGroupInfo = false
    @Environment(\.dismiss) private var dismiss

    private var conversation: GroupConversation? {
        groupService.conversations.first(where: { $0.identifier == identifier })
    }

    private var messages: [GroupMessage] {
        conversation?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages ScrollView
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { message in
                                GroupMessageBubbleView(
                                    message: message,
                                    senderProfile: nostrService.profiles[message.senderPubkey],
                                    containerWidth: geometry.size.width,
                                    isAdmin: groupService.isAdmin(in: identifier),
                                    onDelete: { eventId in
                                        Task {
                                            try? await groupService.deleteEvent(eventId, fromGroup: identifier)
                                        }
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

                HStack(alignment: .bottom, spacing: 10) {
                    TextField(String(localized: "group.chat.messagePlaceholder"), text: $messageInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.appSystem(size: 15))
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
                                .background(
                                    messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color.secondary.opacity(0.25)
                                        : Color.havenPurple
                                )
                                .clipShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.top, 8)
            }
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor))
            #else
            .background(Color.platformWindowBackground)
            #endif
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .navigationTitle(conversation?.displayName ?? identifier.groupId)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingGroupInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.appSystem(size: 16, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingGroupInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .help(String(localized: "group.chat.info"))
            }
        }
        #endif
        .sheet(isPresented: $showingGroupInfo) {
            GroupInfoView(identifier: identifier)
                .environmentObject(nostrService)
                .environmentObject(configService)
                #if os(macOS)
                .frame(minWidth: 400, minHeight: 400)
                #endif
        }
        .alert(String(localized: "group.chat.sendFailed"), isPresented: Binding<Bool>(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button(String(localized: "group.chat.ok")) { sendError = nil }
        } message: {
            if let sendError = sendError {
                Text(sendError)
            }
        }
        .onAppear {
            groupService.markRead(group: identifier)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func sendMessage() {
        let trimmed = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        let messageToSend = trimmed
        messageInput = ""

        Task {
            do {
                try await groupService.sendMessage(content: messageToSend, toGroup: identifier)
                await MainActor.run {
                    isSending = false
                }
            } catch {
                #if DEBUG
                print("Failed to send group message: \(error)")
                #endif
                await MainActor.run {
                    isSending = false
                    messageInput = messageToSend
                    sendError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Group Message Bubble

struct GroupMessageBubbleView: View {
    let message: GroupMessage
    let senderProfile: FeedProfile?
    var containerWidth: CGFloat = 360
    let isAdmin: Bool
    let onDelete: (String) -> Void

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

    private var senderName: String {
        senderProfile?.bestName ?? String(message.senderPubkey.prefix(8)) + "..."
    }

    private var kindLabel: String? {
        switch message.kind {
        case 11: return "Thread"
        case 12: return "Reply"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isFromMe {
                Spacer(minLength: 60)
            } else {
                if let profile = senderProfile {
                    AvatarView(url: profile.pictureURL, pubkey: message.senderPubkey)
                        .frame(width: 28, height: 28)
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
                // Sender name for received messages
                if !message.isFromMe {
                    Text(senderName)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .padding(.horizontal, 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Kind badge for threads
                    if let label = kindLabel {
                        HStack(spacing: 3) {
                            Image(systemName: message.kind == 11 ? "text.bubble" : "arrowshape.turn.up.left")
                                .font(.appSystem(size: 9, weight: .medium))
                            Text(label)
                                .font(.appSystem(size: 9, weight: .medium))
                        }
                        .foregroundColor(message.isFromMe ? .white.opacity(0.6) : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }

                    Text(message.content)
                        .font(.appSystem(size: 15))
                        .foregroundColor(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .textSelection(.enabled)
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
                .contextMenu {
                    if isAdmin && !message.isFromMe {
                        Button(role: .destructive) {
                            onDelete(message.id)
                        } label: {
                            Label(String(localized: "group.chat.deleteMessage"), systemImage: "trash")
                        }
                    }
                }

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
