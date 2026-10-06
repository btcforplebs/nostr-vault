import SwiftUI
import Combine

/// The Hashtags feed: posts carrying the hashtags you follow (your kind 10015
/// interest list). Same scope as the hashtag sheet: people you follow first,
/// then your network, Everyone only through the app-wide shield.
struct HashtagsFeedSection<Row: View, ThreadRow: View>: View {
    /// Threaded layout: whole conversations instead of loose posts.
    let threaded: Bool
    /// Draws one post the way the main feed does (navigation, actions).
    let row: (FeedNote) -> Row
    /// Draws one conversation the way the main feed's threaded layout does.
    let threadRow: (FeedThread<FeedNote>) -> ThreadRow

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var interests = InterestListService.shared
    @StateObject private var model = HashtagFeedModel(tags: [])
    @StateObject private var suggestions = HashtagSuggestionsModel()
    /// The chip narrowing the feed to one tag; nil is All.
    @State private var selected: String?
    @State private var showingFollowFailed = false

    init(
        threaded: Bool,
        @ViewBuilder row: @escaping (FeedNote) -> Row,
        @ViewBuilder threadRow: @escaping (FeedThread<FeedNote>) -> ThreadRow
    ) {
        self.threaded = threaded
        self.row = row
        self.threadRow = threadRow
    }

    private var everyone: Bool { configService.config.globalShowsEveryone }
    private var shownTags: [String] {
        if let selected, interests.hashtags.contains(selected) { return [selected] }
        return interests.hashtags
    }

    var body: some View {
        VStack(spacing: 12) {
            if interests.hashtags.isEmpty {
                noTagsState
            } else {
                chipRow
                if model.fromFollows.isEmpty && model.fromOthers.isEmpty {
                    noPostsState
                }
                if threaded {
                    threadedList
                } else {
                    LazyVStack(spacing: 12) {
                        if !model.fromFollows.isEmpty {
                            sectionHeader("From people you follow")
                            ForEach(model.fromFollows) { row($0) }
                        }
                        if !model.fromOthers.isEmpty {
                            sectionHeader(everyone ? "More from everyone" : "More from your network")
                            ForEach(model.fromOthers) { row($0) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            interests.refreshIfNeeded()
            restart()
        }
        .onDisappear { model.stop() }
        .onChange(of: interests.hashtags) { _, tags in
            if let selected, !tags.contains(selected) { self.selected = nil }
            restart()
        }
        .onChange(of: selected) { _, _ in restart() }
        // The follow list and the trust graph can arrive after the feed opens.
        .onChange(of: feedService.followedPubkeys.count) { _, _ in restart() }
        .onChange(of: feedService.wotPubkeys.count) { _, _ in restart() }
        .onChange(of: everyone) { _, _ in restart() }
        .alert("Couldn't save", isPresented: $showingFollowFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your relays didn't answer, so your hashtag list wasn't changed. Try again in a moment.")
        }
    }

    /// Your own posts count with your follows, like the hashtag sheet.
    private func restart() {
        var follows = Set(feedService.followedPubkeys)
        if !configService.activeAccountHexPubkey.isEmpty { follows.insert(configService.activeAccountHexPubkey) }
        if interests.hashtags.isEmpty {
            model.stop()
            suggestions.load(follows: Set(feedService.followedPubkeys), excluding: [])
            return
        }
        model.start(tags: shownTags, follows: follows, trust: feedService.globalTrustSet())
    }

    private func setFollowing(_ tag: String, _ followed: Bool) {
        Task {
            if await !interests.setFollowing(tag, followed) { showingFollowFailed = true }
        }
    }

    // MARK: Chips

    /// All, then one chip per followed tag. Tap narrows; long press unfollows.
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: selected == nil) { selected = nil }
                ForEach(interests.hashtags, id: \.self) { tag in
                    chip("#\(tag)", isSelected: selected == tag) {
                        selected = selected == tag ? nil : tag
                    }
                    .contextMenu {
                        Button(role: .destructive) { setFollowing(tag, false) } label: {
                            Label("Unfollow #\(tag)", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(isSelected ? .white : .havenPurple)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty states

    private var noTagsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "number").font(.appSystem(size: 30)).foregroundColor(.havenPurple.opacity(0.7))
            Text("Follow a hashtag to see it here")
                .font(.appSystem(size: 16, weight: .bold))
            if suggestions.isLoading && suggestions.tags.isEmpty {
                ProgressView().padding(.top, 8)
            } else if suggestions.tags.isEmpty {
                Text("Tap a #hashtag in any post to follow it.")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Popular with people you follow")
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(suggestions.tags, id: \.self) { tag in
                        suggestionRow(tag)
                        if tag != suggestions.tags.last { Divider() }
                    }
                }
                .background(Color.havenPurple.opacity(0.05))
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }

    private func suggestionRow(_ tag: String) -> some View {
        let followed = interests.isFollowing(tag)
        return HStack {
            Text("#\(tag)")
                .font(.appSystem(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button { setFollowing(tag, !followed) } label: {
                HStack(spacing: 6) {
                    Image(systemName: followed ? "checkmark" : "plus")
                        .font(.appSystem(size: 12, weight: .semibold))
                    Text(followed ? "Following" : "Follow")
                        .font(.appSystem(size: 13, weight: .semibold))
                }
                .foregroundColor(followed ? .white : .havenPurple)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(followed ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(configService.activeAccountHexPubkey.isEmpty)
            .accessibilityLabel(followed ? "Unfollow #\(tag)" : "Follow #\(tag)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var noPostsState: some View {
        VStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
            } else {
                Text(everyone ? "No posts in your hashtags yet"
                              : "No posts in your hashtags from people you follow or your network yet")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if !everyone {
                    Text("The shield above shows everyone.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }

    // MARK: Threaded

    /// Both sections grouped into conversations in one pass, so a reply from
    /// your network and one from a follow land in the same card. A card goes
    /// on top when anyone you follow posted in it: "following first" still
    /// holds, and no conversation is split across the two sections.
    private var threadedList: some View {
        let followIds = Set(model.fromFollows.map(\.id))
        let blocked = configService.activeAccountBlockedHexPubkeys
        let threads = FeedThreadGrouping.build(notes: model.fromFollows + model.fromOthers) { id in
            guard let note = feedService.findNote(id: id), !blocked.contains(note.pubkey) else { return nil }
            return note
        }
        let top = threads.filter { $0.entries.contains { followIds.contains($0.note.id) } }
        let rest = threads.filter { !$0.entries.contains { followIds.contains($0.note.id) } }
        return LazyVStack(spacing: 12) {
            if !top.isEmpty {
                sectionHeader("From people you follow")
                ForEach(top) { threadRow($0) }
            }
            if !rest.isEmpty {
                sectionHeader(everyone ? "More from everyone" : "More from your network")
                ForEach(rest) { threadRow($0) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

/// One look at recent posts by the people you follow, to suggest the
/// hashtags they use most.
@MainActor
final class HashtagSuggestionsModel: ObservableObject {
    @Published private(set) var tags: [String] = []
    @Published private(set) var isLoading = false

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: [[String]]] = [:]
    private var loadedFor: Set<String> = []
    private var excluded: Set<String> = []
    private var generation = 0

    /// Asks again only when the follow list changed.
    func load(follows: Set<String>, excluding followed: Set<String>) {
        excluded = followed
        guard !follows.isEmpty else {
            stop()
            tags = []
            isLoading = false
            return
        }
        guard follows != loadedFor else {
            recompute()
            return
        }
        stop()
        loadedFor = follows
        generation += 1
        let gen = generation
        collected = [:]
        isLoading = true

        let filter: [String: Any] = [
            "kinds": [1],
            "authors": Array(follows.sorted().prefix(FeedService.trustedAuthorsCap)),
            "limit": 500,
        ]
        let subId = "tagtop-\(UUID().uuidString.prefix(8))"
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: data, encoding: .utf8) else {
            isLoading = false
            return
        }
        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        var answered = 0
        for relay in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &cancellables)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    guard let self, self.generation == gen,
                          let data = message.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          array.count >= 2, let type = array[0] as? String,
                          array[1] as? String == subId else { return }
                    if type == "EOSE" {
                        answered += 1
                        self.recompute()
                        if answered >= relays.count { self.finish(gen) }
                    } else if type == "EVENT", array.count >= 3,
                              let ev = array[2] as? [String: Any],
                              let id = ev["id"] as? String,
                              let tags = ev["tags"] as? [[String]] {
                        self.collected[id] = tags
                    }
                }
                .store(in: &cancellables)
            client.connect(url: relay)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(gen) }
    }

    func stop() {
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables.removeAll()
    }

    private func finish(_ gen: Int) {
        guard generation == gen, isLoading else { return }
        recompute()
        isLoading = false
        stop()
    }

    private func recompute() {
        tags = HashtagSuggestions.top(Array(collected.values), excluding: excluded)
    }
}
