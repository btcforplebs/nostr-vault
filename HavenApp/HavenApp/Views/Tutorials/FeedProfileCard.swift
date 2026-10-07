import SwiftUI

/// Follow or unfollow with the app's usual banners: a queued action while the
/// follow list is still loading, a failure message otherwise. Shared by the
/// profile page and the small profile card.
@MainActor
enum FollowActions {
    static func toggle(_ pubkey: String, name: String, isFollowing: Bool) {
        let feed = FeedService.shared
        if isFollowing {
            switch feed.unfollowUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .unfollowed)
            case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                // Queued until the follow list is confirmed; not an error.
                FollowNotificationManager.shared.addPending(pubkey: pubkey, recipientName: name, follow: false)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(unfollowErrorMessage(err)))
            }
        } else {
            switch feed.followUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .followed)
            case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                FollowNotificationManager.shared.addPending(pubkey: pubkey, recipientName: name, follow: true)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(followErrorMessage(err)))
            }
        }
    }

    private static func followErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded, .listUnavailable: return "Following once your follow list loads…"
        case .alreadyFollowing:  return "Already following"
        case .cannotUnfollowSelf: return "Follow failed"
        }
    }

    private static func unfollowErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded, .listUnavailable: return "Unfollowing once your follow list loads…"
        case .cannotUnfollowSelf: return "Can't unfollow yourself"
        case .alreadyFollowing:   return "Unfollow failed"
        }
    }
}

/// "Look before you follow": a half-height card with someone's bio, how many
/// people they follow, their 3 latest posts and Follow, opened from the feed
/// while the Fill your feed meter is up. Follow never waits on the posts: a
/// slow relay leaves the bio and the button usable. "See full profile" opens
/// the usual profile page.
struct FeedProfileCard: View {
    let pubkey: String

    @ObservedObject private var nostr = NostrService.shared
    @ObservedObject private var feed = FeedService.shared
    @ObservedObject private var guide = FillYourVaultCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followingCount: Int?
    @State private var posts: [NostrEvent] = []
    @State private var loadingPosts = true
    @State private var showingFullProfile = false

    private var profile: FeedProfile? { nostr.profiles[pubkey] }
    private var isFollowing: Bool { feed.followedPubkeys.contains(pubkey) }
    private var name: String { profile?.bestName ?? String(pubkey.prefix(10)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.appTitle3.weight(.bold))
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        if let nip05 = profile?.nip05, !nip05.isEmpty {
                            Text(nip05).font(.appSubheadline).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                if let about = profile?.about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                    Text(about)
                        .font(.appSubheadline)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let followingCount {
                    (Text("\(followingCount)").bold() + Text(" following"))
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
                Button(action: toggleFollow) {
                    Label(isFollowing ? "Following" : "Follow",
                          systemImage: isFollowing ? "checkmark" : "person.badge.plus")
                        .font(.appBody.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(isFollowing ? Color(white: 0.25) : Color.havenPurple))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFollowing ? "Following \(name). Tap to unfollow." : "Follow \(name)")

                Text("Recent posts")
                    .font(.appCaption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                if posts.isEmpty {
                    Text(loadingPosts ? "Loading posts…" : "No recent posts found.")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(posts, id: \.id) { post in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.content)
                            .font(.appSubheadline)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Date(timeIntervalSince1970: TimeInterval(post.created_at)), style: .relative)
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
                Button("See full profile") { showingFullProfile = true }
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(.havenPurple)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
        }
        .task(id: pubkey) { await load() }
        .sheet(isPresented: $showingFullProfile) {
            ProfileView(pubkey: pubkey, onDismiss: { showingFullProfile = false })
        }
    }

    private func toggleFollow() {
        let wasFollowing = isFollowing
        FollowActions.toggle(pubkey, name: name, isFollowing: wasFollowing)
        // A new follow fills the meter: close the card so it shows.
        if !wasFollowing {
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.45)) {
                if guide.profileCardPubkey == pubkey { guide.profileCardPubkey = nil }
            }
        }
    }

    private func load() async {
        if profile == nil { nostr.fetchMissingProfiles(for: [pubkey]) }
        // Posts already on screen first; the relays fill in the rest.
        let shown = feed.notes.filter { $0.pubkey == pubkey && $0.kind == 1 }
        if !shown.isEmpty {
            posts = shown.sorted { $0.createdAt > $1.createdAt }.prefix(3).map {
                NostrEvent(id: $0.id, pubkey: $0.pubkey, created_at: Int64($0.createdAt.timeIntervalSince1970),
                           kind: 1, tags: $0.tags, content: $0.content, sig: "")
            }
        }
        async let contacts = nostr.fetchNewestReplaceable(kind: 3, for: pubkey, alsoAsk: [])
        async let recent = nostr.fetchRecentNotes(author: pubkey, limit: 3)
        let fetched = await recent
        if !fetched.isEmpty { posts = fetched }
        loadingPosts = false
        if let list = await contacts {
            followingCount = list.tags.filter { $0.count >= 2 && $0[0] == "p" && $0[1] != pubkey }.count
        }
    }
}
