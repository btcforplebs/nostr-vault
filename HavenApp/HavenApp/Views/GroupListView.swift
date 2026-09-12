import SwiftUI

struct GroupListView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var groupService = GroupService.shared

    @State private var showingBrowser = false

    var body: some View {
        if groupService.conversations.isEmpty {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        Spacer()

                        ZStack {
                            Circle()
                                .fill(Color.havenPurple.opacity(0.08))
                                .frame(width: 100, height: 100)
                            Circle()
                                .fill(Color.havenPurple.opacity(0.05))
                                .frame(width: 130, height: 130)
                            Image(systemName: "person.3")
                                .font(.appSystem(size: 36, weight: .light))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.havenPurple, .havenPurpleLight],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }

                        VStack(spacing: 8) {
                            Text(String(localized: "group.list.empty.title"))
                                .font(.appSystem(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(String(localized: "group.list.empty.subtitle"))
                                .font(.appSystem(size: 14))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                        }

                        Button(action: { showingBrowser = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                Text(String(localized: "group.list.browse"))
                            }
                            .font(.appSystem(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.havenPurple)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .background(Color.platformWindowBackground.ignoresSafeArea())
            .sheet(isPresented: $showingBrowser) {
                GroupBrowserView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
        } else {
            List {
                ForEach(groupService.conversations) { conversation in
                    NavigationLink(destination: GroupChatView(identifier: conversation.identifier)
                        .environmentObject(nostrService)
                        .environmentObject(configService)) {
                        GroupConversationRow(conversation: conversation, nostrService: nostrService)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.platformSecondaryGroupedBackground)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.platformWindowBackground.ignoresSafeArea())
            // No browse or create sheet on this branch: the only button that
            // sets `showingBrowser` lives in the empty state above, and the host
            // (DMInboxView) owns both entry points once there are conversations.
        }
    }
}

// MARK: - Group Conversation Row

struct GroupConversationRow: View {
    let conversation: GroupConversation
    let nostrService: NostrService

    private var hasUnread: Bool {
        conversation.unreadCount > 0
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                if let url = conversation.info?.pictureURL {
                    AvatarView(url: url, pubkey: conversation.identifier.groupId)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.havenPurple.opacity(0.15))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: "person.3.fill")
                                .font(.appSystem(size: 20))
                                .foregroundColor(.havenPurple)
                        )
                }

                if hasUnread {
                    Circle()
                        .fill(Color.havenPurple)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(Color.platformSecondaryGroupedBackground, lineWidth: 2)
                        )
                        .offset(x: 2, y: -1)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(conversation.displayName)
                        .font(.appSystem(size: 15, weight: hasUnread ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if conversation.info?.isPrivate == true {
                        Image(systemName: "lock.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)

                    if let lastMsg = conversation.lastMessage {
                        Text(lastMsg.timestamp.formatted(.relative(presentation: .numeric)))
                            .font(.appSystem(size: 12, weight: .regular))
                            .foregroundColor(hasUnread ? .havenPurple : .secondary)
                    }
                }

                HStack(spacing: 8) {
                    if let lastMsg = conversation.lastMessage {
                        HStack(spacing: 4) {
                            if !lastMsg.isFromMe {
                                let senderName = nostrService.profiles[lastMsg.senderPubkey]?.bestName
                                    ?? String(lastMsg.senderPubkey.prefix(6))
                                Text(senderName + ":")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            let preview = lastMsg.content.prefix(50)
                            Text(preview + (lastMsg.content.count > 50 ? "..." : ""))
                                .font(.appSystem(size: 13, weight: hasUnread ? .medium : .regular))
                                .foregroundColor(hasUnread ? .primary.opacity(0.8) : .secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(String(localized: "group.list.noMessages"))
                            .font(.appSystem(size: 13, weight: .regular))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)

                    if conversation.unreadCount > 1 {
                        Text("\(conversation.unreadCount)")
                            .font(.appSystem(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
