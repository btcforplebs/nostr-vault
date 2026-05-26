import SwiftUI

struct DMInboxView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedConversation: String?
    @State private var showingDMThread = false
    @State private var showingCompose = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if dmService.conversations.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No Messages Yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Tap + to start a conversation")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
                } else {
                    List {
                        ForEach(dmService.conversations) { conversation in
                            NavigationLink(destination: DMThreadView(counterpartyPubkey: conversation.id)
                                .environmentObject(nostrService)
                                .environmentObject(configService)) {
                                ConversationRow(conversation: conversation, nostrService: nostrService)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.platformSecondaryGroupedBackground)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
                    .refreshable {
                        dmService.refresh()
                    }
                }
            }
            .navigationTitle("Messages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingCompose = true }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                MessageComposerView(recipientPubkey: nil)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
            #else
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { showingCompose = true }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    }
                    .help("New Message")
                }
            }
            .sheet(isPresented: $showingCompose) {
                MacComposeView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .frame(minWidth: 400, minHeight: 350)
            }
            #endif
        }
    }
}

// MARK: - macOS Compose View

#if os(macOS)
struct MacComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    @State private var selectedRecipient: String?
    @State private var messageText = ""
    @State private var searchText = ""
    @State private var isSending = false

    private var searchResults: [String] {
        if searchText.isEmpty { return [] }
        return Array(nostrService.profiles.keys.filter { pubkey in
            let profile = nostrService.profiles[pubkey]
            let name = profile?.bestName ?? ""
            return name.lowercased().contains(searchText.lowercased()) ||
                   pubkey.lowercased().contains(searchText.lowercased())
        }.prefix(10))
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedRecipient != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Message")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundColor(.havenPurple)
            }
            .padding()

            Divider()

            // Recipient
            if let recipient = selectedRecipient {
                HStack(spacing: 10) {
                    Text("To:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    AvatarView(url: nostrService.profiles[recipient]?.pictureURL, pubkey: recipient)
                        .frame(width: 24, height: 24)
                    Text(nostrService.profiles[recipient]?.bestName ?? String(recipient.prefix(8)) + "...")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(action: { selectedRecipient = nil; searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Search users...", text: $searchText)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)

                    if !searchResults.isEmpty {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(searchResults, id: \.self) { pubkey in
                                    Button(action: { selectedRecipient = pubkey; searchText = "" }) {
                                        HStack(spacing: 10) {
                                            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey)
                                                .frame(width: 28, height: 28)
                                            Text(nostrService.profiles[pubkey]?.bestName ?? String(pubkey.prefix(8)))
                                                .font(.system(size: 13))
                                                .foregroundColor(.primary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()

            // Message
            TextEditor(text: $messageText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 100)

            Divider()

            // Send
            HStack {
                Spacer()
                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text("Send")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.havenPurple)
                .disabled(!canSend || isSending)
            }
            .padding()
        }
    }

    private func sendMessage() {
        guard let recipient = selectedRecipient else { return }
        isSending = true
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await dmService.sendDM(content: content, to: recipient)
                await MainActor.run { dismiss() }
            } catch {
                print("Failed to send message: \(error)")
                await MainActor.run { isSending = false }
            }
        }
    }
}
#endif

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: DMConversation
    let nostrService: NostrService

    private var counterpartyProfile: FeedProfile? {
        nostrService.profiles[conversation.id]
    }

    private var counterpartyName: String {
        counterpartyProfile?.bestName ?? String(conversation.id.prefix(8)) + "…"
    }

    private var lastMessagePreview: String {
        let message = conversation.lastMessage?.content ?? ""
        if message.isEmpty {
            return "(empty message)"
        }
        return message.prefix(50).trimmingCharacters(in: .whitespaces) + (message.count > 50 ? "…" : "")
    }

    private var lastMessageTime: String {
        guard let lastMessage = conversation.lastMessage else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastMessage.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: counterpartyProfile?.pictureURL, pubkey: conversation.id)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(counterpartyName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(lastMessageTime)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text(lastMessagePreview)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if conversation.unreadCount > 0 {
                        Spacer(minLength: 0)

                        ZStack {
                            Circle()
                                .fill(Color.havenPurple)

                            Text("\(conversation.unreadCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 20, height: 20)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

#Preview {
    DMInboxView()
        .environmentObject(NostrService.shared)
        .environmentObject(ConfigService.shared)
}
