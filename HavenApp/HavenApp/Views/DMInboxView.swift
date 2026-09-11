import SwiftUI

struct DMInboxView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var dmService = DMService.shared
    @StateObject private var groupService = GroupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedConversation: String?
    @State private var showingDMThread = false
    @State private var showingCompose = false
    @State private var showingGroupBrowser = false
    @State private var showingGroupCreate = false
    @State private var selectedTab: InboxTab = .dms

    enum InboxTab: String, CaseIterable {
        case dms = "DMs"
        case groups = "Groups"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker
                Picker("", selection: $selectedTab) {
                    ForEach(InboxTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch selectedTab {
                case .dms:
                    dmContentView
                case .groups:
                    GroupListView()
                        .environmentObject(nostrService)
                        .environmentObject(configService)
                }
            }
            .navigationTitle(String(localized: "dm.inbox.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "dm.inbox.close")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if selectedTab == .dms {
                            Button(action: { dmService.markAllAsRead() }) {
                                Image(systemName: "checkmark.circle")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "dm.inbox.markAllRead"))

                            Button(action: { showingCompose = true }) {
                                Image(systemName: "square.and.pencil")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                        } else {
                            Button(action: { showingGroupBrowser = true }) {
                                Image(systemName: "magnifyingglass")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }

                            Button(action: { showingGroupCreate = true }) {
                                Image(systemName: "plus")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                MessageComposerView(recipientPubkey: nil)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
            .sheet(isPresented: $showingGroupBrowser) {
                GroupBrowserView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
            .sheet(isPresented: $showingGroupCreate) {
                GroupCreateView()
                    .environmentObject(configService)
            }
            #else
            .toolbar {
                // The sheet has no title bar and macOS has no swipe-to-dismiss: without
                // this the inbox could only be closed by quitting the window.
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "dm.inbox.close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        if selectedTab == .dms {
                            // macOS has no pull-to-refresh, so `.refreshable` on the
                            // conversation list was a refresh path with no pointer or
                            // keyboard way to reach it.
                            Button(action: { dmService.refresh() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "dm.inbox.refresh"))
                            .keyboardShortcut("r", modifiers: .command)

                            Button(action: { dmService.markAllAsRead() }) {
                                Image(systemName: "checkmark.circle")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "dm.inbox.markAllRead"))

                            Button(action: { showingCompose = true }) {
                                Image(systemName: "square.and.pencil")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "dm.inbox.newMessage"))
                        } else {
                            Button(action: { showingGroupBrowser = true }) {
                                Image(systemName: "magnifyingglass")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "group.toolbar.browse"))

                            Button(action: { showingGroupCreate = true }) {
                                Image(systemName: "plus")
                                    .font(.appSystem(size: 15, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .help(String(localized: "group.toolbar.create"))
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                MacComposeView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .frame(minWidth: 400, minHeight: 350)
            }
            .sheet(isPresented: $showingGroupBrowser) {
                GroupBrowserView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .frame(minWidth: 450, minHeight: 400)
            }
            .sheet(isPresented: $showingGroupCreate) {
                GroupCreateView()
                    .environmentObject(configService)
                    .frame(minWidth: 400, minHeight: 350)
            }
            #endif
        }
    }

    // MARK: - DM Content

    @ViewBuilder
    private var dmContentView: some View {
        if dmService.conversations.isEmpty {
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
                            Image(systemName: "bubble.left.and.bubble.right")
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
                            Text(String(localized: "dm.inbox.empty.title"))
                                .font(.appSystem(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(String(localized: "dm.inbox.empty.subtitle"))
                                .font(.appSystem(size: 14))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                        }

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .refreshable {
                    dmService.refresh()
                }
            }
            .background(Color.platformWindowBackground.ignoresSafeArea())
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
            .background(Color.platformWindowBackground.ignoresSafeArea())
            .refreshable {
                dmService.refresh()
            }
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
    @State private var sendError: String?

    private var searchResults: [String] {
        if searchText.count < 2 { return [] }
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
                Text(String(localized: "dm.compose.title"))
                    .font(.appSystem(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "dm.compose.cancel")) { dismiss() }
                    .foregroundColor(.havenPurple)
            }
            .padding()

            Divider()

            // Recipient
            if let recipient = selectedRecipient {
                HStack(spacing: 10) {
                    Text(String(localized: "dm.compose.to"))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    AvatarView(url: nostrService.profiles[recipient]?.pictureURL, pubkey: recipient)
                        .frame(width: 24, height: 24)
                    Text(nostrService.profiles[recipient]?.bestName ?? String(recipient.prefix(8)) + "...")
                        .font(.appSystem(size: 13, weight: .medium))
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
                    TextField(String(localized: "dm.compose.searchPlaceholder"), text: $searchText)
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
                                                .font(.appSystem(size: 13))
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
                .font(.appSystem(size: 13))
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
                            Text(String(localized: "dm.compose.send"))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.havenPurple)
                .disabled(!canSend || isSending)
            }
            .padding()
        }
        .alert(String(localized: "dm.compose.sendFailed"), isPresented: Binding<Bool>(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button(String(localized: "dm.compose.ok")) { sendError = nil }
        } message: {
            if let sendError = sendError {
                Text(sendError)
            }
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
                #if DEBUG
                print("Failed to send message: \(error)")
                #endif
                await MainActor.run {
                    isSending = false
                    sendError = error.localizedDescription
                }
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
            return String(localized: "dm.inbox.noContent")
        }
        return message.prefix(60).trimmingCharacters(in: .whitespaces) + (message.count > 60 ? "…" : "")
    }

    private var lastMessageTime: String {
        guard let lastMessage = conversation.lastMessage else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastMessage.timestamp, relativeTo: Date())
    }

    private var hasUnread: Bool {
        conversation.unreadCount > 0
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                AvatarView(url: counterpartyProfile?.pictureURL, pubkey: conversation.id)
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())

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
                    Text(counterpartyName)
                        .font(.appSystem(size: 15, weight: hasUnread ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(lastMessageTime)
                        .font(.appSystem(size: 12, weight: .regular))
                        .foregroundColor(hasUnread ? .havenPurple : .secondary)
                }

                HStack(spacing: 8) {
                    Text(lastMessagePreview)
                        .font(.appSystem(size: 13, weight: hasUnread ? .medium : .regular))
                        .foregroundColor(hasUnread ? .primary.opacity(0.8) : .secondary)
                        .lineLimit(2)

                    if conversation.unreadCount > 1 {
                        Spacer(minLength: 0)

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

#Preview {
    DMInboxView()
        .environmentObject(NostrService.shared)
        .environmentObject(ConfigService.shared)
}
