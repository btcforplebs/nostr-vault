import SwiftUI

struct DMThreadView: View {
    let counterpartyPubkey: String

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    @State private var messageInput: String = ""
    @State private var isSending: Bool = false
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
                            .font(.system(size: 12, weight: .semibold))
                        Text("This conversation contains NIP-04 messages with weaker encryption. New messages use NIP-17.")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                // Messages ScrollView
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    profile: counterpartyProfile
                                )
                                .id(message.id)
                            }

                            // Spacer to push messages up
                            Spacer()
                                .frame(height: 0)
                                .id("bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .onAppear {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: messages.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                }

                Divider()

                // Protocol Toggle
                HStack(spacing: 8) {
                    Text("Protocol:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Button(action: { useNIP04 = false }) {
                        Text("NIP-17")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(useNIP04 ? .secondary : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(useNIP04 ? Color.secondary.opacity(0.1) : Color.havenPurple)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: { useNIP04 = true }) {
                        Text("NIP-04")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(useNIP04 ? .white : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(useNIP04 ? Color.orange : Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .help(useNIP04 ? "NIP-04: Legacy encryption (weaker security)" : "NIP-17: Modern encryption (recommended)")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Input Area
                HStack(spacing: 12) {
                    TextField("Message...", text: $messageInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(20)

                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "arrow.up.circle" : "arrow.up.circle.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(
                                    messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? .secondary
                                        : .havenPurple
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                #if os(macOS)
                .background(Color(nsColor: .controlBackgroundColor))
                #else
                .background(Color(uiColor: .systemBackground))
                #endif
            }
            .navigationTitle(counterpartyProfile?.bestName ?? "DM")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                print("❌ Failed to send DM: \(error)")
                await MainActor.run {
                    isSending = false
                    messageInput = messageToSend
                }
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: DMMessage
    let profile: FeedProfile?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isFromMe {
                Spacer()
            } else {
                // Counterparty avatar
                if let profile = profile {
                    AvatarView(url: profile.pictureURL, pubkey: message.senderPubkey)
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 8)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .padding(.trailing, 8)
                }
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                // Message content with protocol badge
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.content)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)

                    if message.isNIP04 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.shield")
                                .font(.system(size: 8, weight: .semibold))
                            Text("NIP-04")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(message.isFromMe ? .white.opacity(0.7) : .orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
                .background(message.isFromMe ? Color.havenPurple : Color.secondary.opacity(0.15))
                .cornerRadius(16)

                HStack(spacing: 4) {
                    Text(message.timestamp.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: 280, alignment: message.isFromMe ? .trailing : .leading)

            if message.isFromMe {
                // Own message - no avatar needed
            } else {
                Spacer()
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
