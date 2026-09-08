import SwiftUI

struct DMThreadView: View {
    let counterpartyPubkey: String

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    @State private var messageInput: String = ""
    @State private var isSending: Bool = false
    @State private var sendError: String?
    @State private var scrollPosition: String?
    @State private var useNIP04: Bool = false
    @Environment(\.dismiss) private var dismiss

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
                                        containerWidth: geometry.size.width
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

                    // Message input
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Message...", text: $messageInput, axis: .vertical)
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
            .onAppear {
                dmService.markRead(conversationWith: counterpartyPubkey)
            }
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
                try await dmService.sendDM(content: messageToSend, to: counterpartyPubkey, useNIP04: useNIP04)
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.content)
                        .font(.appSystem(size: 15))
                        .foregroundColor(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .textSelection(.enabled)

                    if message.isNIP04 {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.open")
                                .font(.appSystem(size: 8, weight: .medium))
                            Text("NIP-04")
                                .font(.appSystem(size: 9, weight: .medium))
                        }
                        .foregroundColor(message.isFromMe ? .white.opacity(0.6) : .orange.opacity(0.8))
                        .padding(.horizontal, 14)
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
