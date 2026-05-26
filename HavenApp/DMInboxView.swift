import SwiftUI

struct DMInboxView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared

    @State private var selectedConversation: String?
    @State private var showingDMThread = false

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
                        Text("Start a conversation by visiting a profile")
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
                }
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

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
