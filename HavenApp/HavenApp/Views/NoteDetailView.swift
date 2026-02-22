import SwiftUI
import Combine

struct NoteDetailView: View {
    let note: FeedNote
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingReplyCompose = false
    @State private var replies: [FeedNote] = []
    @State private var isLoadingReplies = false
    @State private var parentNotes: [FeedNote] = []
    @State private var isLoadingParents = false
    @State private var threadClient: WebSocketClient?
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Thread History (Parents)
                if !parentNotes.isEmpty {
                    threadSection
                    Divider()
                }

                // Main Note
                mainNoteSection

                Divider()

                // Replies Section
                repliesSection
            }
            .padding()
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingReplyCompose = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                }
            }
        }
        .sheet(isPresented: $showingReplyCompose) {
            ComposeView(replyTo: note)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .onAppear {
            fetchParents()
            fetchReplies()
        }
        .onDisappear {
            threadClient?.disconnect()
            cancellables.removeAll()
        }
    }
    
    private var mainNoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(url: feedService.profiles[note.pubkey]?.pictureURL, pubkey: note.pubkey)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(feedService.profiles[note.pubkey]?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                        .font(.headline)
                    Text(relativeTime(note.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Text(note.content)
                .font(.body)
                .textSelection(.enabled)
            
            if !note.mediaURLs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(note.mediaURLs, id: \.absoluteString) { url in
                        FeedMediaThumbnail(url: url)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                    }
                }
            }
            
            HStack(spacing: 24) {
                actionButton(icon: "message", count: nil) {
                    showingReplyCompose = true
                }
                actionButton(icon: "arrow.2.squarepath", count: nil) {
                    repostNote()
                }
                actionButton(icon: "heart", count: nil) {
                    likeNote()
                }
                Spacer()
            }
            .padding(.top, 8)
        }
    }
    
    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundColor(.secondary)
                Text("Thread Context")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            ForEach(parentNotes) { parent in
                NavigationLink(destination: NoteDetailView(note: parent)) {
                    CompactNoteRow(note: parent, profile: feedService.profiles[parent.pubkey])
                }
                .buttonStyle(.plain)
            }

            if isLoadingParents {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
    }

    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replies")
                .font(.headline)
                .padding(.bottom, 4)

            if isLoadingReplies && replies.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if replies.isEmpty {
                Text("No replies yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(replies) { reply in
                    NavigationLink(destination: NoteDetailView(note: reply)) {
                        FeedNoteRow(note: reply, profile: feedService.profiles[reply.pubkey])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func actionButton(icon: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if let count = count {
                    Text("\(count)")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }
    
    private func fetchReplies() {
        isLoadingReplies = true
        // In a real app, we'd query relays for e-tags pointing to this note id
        // For now, we'll check what we already have in FeedService and maybe a simple relay query
        self.replies = feedService.notes.filter { $0.parentEventId == note.id }
            .sorted(by: { $0.createdAt < $1.createdAt })
        isLoadingReplies = false
    }
    
    private func likeNote() {
        guard let signed = nostrService.signEvent(kind: 7, content: "+", tags: [["e", note.id], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }
    
    private func repostNote() {
        guard let signed = nostrService.signEvent(kind: 6, content: "", tags: [["e", note.id], ["p", note.pubkey]]) else { return }
        nostrService.postEvent(signed)
    }

    // MARK: - Thread Loading

    private func fetchParents() {
        guard let parentId = note.parentEventId, !isLoadingParents else { return }
        isLoadingParents = true

        let relayURL = URL(string: configService.config.nostrURL)!
        let client = WebSocketClient()
        threadClient = client

        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { msg in
                self.handleParentMessage(msg, client: client)
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    // Request the parent note
                    let filter: [String: Any] = ["ids": [parentId], "limit": 1]
                    let req = ["REQ", "thread-\(UUID().uuidString.prefix(8))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
            }
            .store(in: &cancellables)

        client.connect(url: relayURL)
    }

    private func handleParentMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            let parent = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )

            // Insert parent at the beginning to maintain chronological order
            parentNotes.insert(parent, at: 0)

            // Recursively fetch the parent's parent
            if let grandparentId = parent.parentEventId {
                fetchParentNote(id: grandparentId, client: client)
            } else {
                isLoadingParents = false
                client.disconnect()
            }

            // Fetch profile for the parent note author
            if feedService.profiles[pubkey] == nil {
                fetchProfile(for: pubkey)
            }
        } else if type == "EOSE" {
            isLoadingParents = false
            client.disconnect()
        }
    }

    private func fetchParentNote(id: String, client: WebSocketClient) {
        let filter: [String: Any] = ["ids": [id], "limit": 1]
        let req = ["REQ", "thread-\(UUID().uuidString.prefix(8))", filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    private func fetchProfile(for pubkey: String) {
        let client = WebSocketClient()
        var got = false

        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { msg in
                guard !got else { return }
                self.handleProfileMessage(msg, pubkey: pubkey, client: client, onSuccess: { got = true })
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let filter: [String: Any] = ["kinds": [0], "authors": [pubkey], "limit": 1]
                    let req = ["REQ", "p-\(pubkey.prefix(6))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
            }
            .store(in: &cancellables)

        client.connect(url: URL(string: configService.config.nostrURL)!)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            client.disconnect()
        }
    }

    private func handleProfileMessage(
        _ msg: String, pubkey: String, client: WebSocketClient, onSuccess: (() -> Void)? = nil
    ) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String, type == "EVENT",
              json.count >= 3,
              let ev = json[2] as? [String: Any],
              let kind = ev["kind"] as? Int, kind == 0,
              let contentStr = ev["content"] as? String,
              let metaData = contentStr.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        else { return }

        let profile = FeedProfile(
            pubkey: pubkey,
            name: meta["name"] as? String,
            displayName: meta["display_name"] as? String,
            pictureURL: (meta["picture"] as? String).flatMap { URL(string: $0) },
            nip05: meta["nip05"] as? String
        )
        feedService.profiles[pubkey] = profile
        onSuccess?()
        client.disconnect()
    }
    
    private func relativeTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - CompactNoteRow

struct CompactNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey)
                    .frame(width: 28, height: 28)

                Text(profile?.bestName ?? "npub…" + String(note.pubkey.suffix(6)))
                    .font(.caption.bold())

                Spacer()

                Text(relativeTime(note.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(note.content)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private func relativeTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
