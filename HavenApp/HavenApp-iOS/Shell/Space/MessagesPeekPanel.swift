import SwiftUI

/// Messages peek, the web's third Your space panel: the inbox beside
/// whatever is open, unread chats first, then the rest, each with its last
/// line. Requests and blocked people are left out, as they are from the
/// unread badge. A row opens the conversation. Nothing here publishes.
struct MessagesPeekPanel: View {
    @ObservedObject private var dmService = DMService.shared
    @ObservedObject private var nostrService = NostrService.shared

    static let rows = 12

    /// Unread first, newest first; then the read ones, newest first.
    static func peek(_ conversations: [DMConversation]) -> [DMConversation] {
        let newest: (DMConversation, DMConversation) -> Bool = {
            ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast)
        }
        let unread = conversations.filter { $0.unreadCount > 0 }.sorted(by: newest)
        let read = conversations.filter { $0.unreadCount == 0 }.sorted(by: newest)
        return Array((unread + read).prefix(rows))
    }

    var body: some View {
        let rows = Self.peek(dmService.visibleConversations)
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("No messages yet")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(rows) { chat in
                    Button { open(chat.id) } label: { row(chat) }
                        .buttonStyle(.plain)
                    if chat.id != rows.last?.id { Divider().padding(.leading, 52) }
                }
            }
            Button { open(nil) } label: {
                Text("All messages")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.havenPurple)
        }
        .onAppear { nostrService.fetchMissingProfiles(for: rows.map(\.id)) }
    }

    private func row(_ chat: DMConversation) -> some View {
        let profile = nostrService.profiles[chat.id]
        return HStack(spacing: 10) {
            AvatarView(url: profile?.pictureURL, pubkey: chat.id, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.bestName ?? String(chat.id.prefix(10)))
                    .font(.appSystem(size: 14, weight: chat.unreadCount > 0 ? .bold : .semibold))
                    .lineLimit(1)
                Text(chat.lastMessage?.content ?? "")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if chat.unreadCount > 0 {
                Circle().fill(Color.havenPurple).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// The inbox sheet, open on `peer`'s conversation when there is one.
    private func open(_ peer: String?) {
        NotificationCenter.default.post(name: .havenOpenDMInbox, object: peer)
    }
}
