import SwiftUI
import Combine

/// The page a profile's Following / Followers counts open: everyone on either
/// list, split into people you follow, your web of trust and everyone else,
/// with a Follow button on each row. Tapping a row pushes that profile onto
/// this page's own stack.
struct FollowListView: View {
    /// The profile whose lists these are.
    let subject: String
    let subjectName: String
    /// Contact-list order.
    let following: [String]
    /// Follower → when their list naming `subject` was published.
    let followers: [String: Int64]
    /// True while the follower list is known to be partial.
    let followersHaveMore: Bool
    /// The profile's follower count as its page shows it, which can be ahead
    /// of the list while pages load.
    var followersTotal: Int? = nil
    /// True when `followers` is the subject's own complete ledger, so every
    /// row follows the viewer and the "follows you" tag would say nothing.
    let isViewersOwnFollowers: Bool
    /// People who follow the viewer, for the "follows you" tag.
    let followsViewer: Set<String>
    /// Spam, hidden from both lists.
    let hidden: Set<String>
    var onLoadMoreFollowers: (() -> Void)? = nil

    @State private var tab: FollowListTab
    @State private var query = ""
    @State private var showOutside = false
    @State private var path: [FollowListRoute] = []
    @State private var trustRank: [String: Int] = [:]
    @State private var webOfTrust: Set<String> = []
    @State private var sortByTab = FollowListSortMemory.shared.sorts
    @StateObject private var follows = FollowListFollowWatch()
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    init(
        subject: String,
        subjectName: String,
        startOn tab: FollowListTab,
        following: [String],
        followers: [String: Int64],
        followersHaveMore: Bool,
        followersTotal: Int? = nil,
        isViewersOwnFollowers: Bool,
        followsViewer: Set<String>,
        hidden: Set<String>,
        onLoadMoreFollowers: (() -> Void)? = nil
    ) {
        self.subject = subject
        self.subjectName = subjectName
        self.following = following
        self.followers = followers
        self.followersHaveMore = followersHaveMore
        self.followersTotal = followersTotal
        self.isViewersOwnFollowers = isViewersOwnFollowers
        self.followsViewer = followsViewer
        self.hidden = hidden
        self.onLoadMoreFollowers = onLoadMoreFollowers
        _tab = State(initialValue: tab)
    }

    private var sort: FollowListSort { sortByTab[tab] ?? .trusted }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(subjectName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(tab.title.lowercased())")
                #else
                .searchable(text: $query, prompt: "Search \(tab.title.lowercased())")
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }
                    ToolbarItem(placement: .primaryAction) { sortMenu }
                }
                #if os(iOS)
                .toolbarBackground(Color.platformWindowBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                #endif
                .navigationDestination(for: FollowListRoute.self) { route in
                    ProfileView(pubkey: route.pubkey, embeddedInNavigation: true)
                }
                .background(Color.platformWindowBackground.ignoresSafeArea())
        }
        .overlay(alignment: .top) { FollowNotificationBanner() }
        .onAppear(perform: loadTrust)
    }

    // MARK: - List

    private var list: some View {
        let sections = currentSections
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections, id: \.group) { section in
                        Section {
                            if section.group != .outside || showOutside || !query.isEmpty {
                                ForEach(section.people, id: \.pubkey) { person in
                                    row(person)
                                    Divider().padding(.leading, 72)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }

                if tab == .followers, followersHaveMore, let onLoadMoreFollowers {
                    ProgressView()
                        .padding(.vertical, 20)
                        // A new identity per page, so a loader still on screen
                        // after a page lands asks for the next one.
                        .id(followers.count)
                        .onAppear(perform: onLoadMoreFollowers)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .solidTopEdge()
        // Title, search and the switch stay put on a solid bar; rows and the
        // pinned group headers slide under it, never show through it.
        .safeAreaInset(edge: .top, spacing: 0) {
            tabPicker
                .frame(maxWidth: 720)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .background(Color.platformWindowBackground)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var currentSections: [FollowListSection] {
        FollowListLogic.sections(
            people: people(for: tab),
            follows: Set(follows.followed),
            webOfTrust: webOfTrust,
            trustRank: trustRank,
            hidden: hidden,
            sort: sort,
            query: query
        )
    }

    private func people(for tab: FollowListTab) -> [FollowListPerson] {
        switch tab {
        case .following:
            return following.enumerated().map { index, key in
                person(key, recency: Int64(index))
            }
        case .followers:
            return followers.map { key, at in person(key, recency: at) }
        }
    }

    private func person(_ key: String, recency: Int64) -> FollowListPerson {
        let profile = nostrService.profiles[key]
        return FollowListPerson(
            pubkey: key,
            name: profile?.bestName ?? Self.shortNpub(key),
            nip05: profile?.nip05 ?? "",
            recency: recency
        )
    }

    private var tabPicker: some View {
        Picker("List", selection: $tab) {
            Text("Following \(FollowListLogic.countText(following.count, more: false))")
                .tag(FollowListTab.following)
            Text("Followers \(followersLabel)")
                .tag(FollowListTab.followers)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Matches the count on the profile: the full total when relays gave one,
    /// otherwise what is loaded, with + while more can load.
    private var followersLabel: String {
        if let followersTotal, followersTotal > followers.count {
            return FollowListLogic.countText(followersTotal, more: false)
        }
        return FollowListLogic.countText(followers.count, more: followersHaveMore)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { sort },
                set: { newValue in
                    sortByTab[tab] = newValue
                    FollowListSortMemory.shared.sorts[tab] = newValue
                }
            )) {
                ForEach(FollowListSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, \(sort.title)")
    }

    private func sectionHeader(_ section: FollowListSection) -> some View {
        let collapsible = section.group == .outside && query.isEmpty
        return HStack(spacing: 6) {
            Text(section.group.title.uppercased())
                .font(.appSystem(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            Text("\(section.people.count)")
                .font(.appSystem(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            if collapsible {
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(showOutside ? 90 : 0))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: collapsible ? 44 : 32)
        .background(Color.platformWindowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            guard collapsible else { return }
            withAnimation(Motion.fade) { showOutside.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(collapsible ? .isButton : [])
        .accessibilityHint(collapsible ? (showOutside ? "Hides this group" : "Shows this group") : "")
    }

    private var emptyState: some View {
        Text(emptyText)
            .font(.appSystem(size: 14))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
    }

    private var emptyText: String {
        if !query.isEmpty { return "No one matches “\(query)”" }
        return tab == .following ? "Not following anyone yet" : "No followers found yet"
    }

    // MARK: - Row

    private func row(_ person: FollowListPerson) -> some View {
        let isViewer = person.pubkey == configService.activeAccountHexPubkey
        return FollowListRow(
            pubkey: person.pubkey,
            name: person.name,
            profile: nostrService.profiles[person.pubkey],
            followsYou: !isViewer && !(tab == .followers && isViewersOwnFollowers) && followsViewer.contains(person.pubkey),
            followState: isViewer ? nil : follows.state(for: person.pubkey),
            onOpen: {
                // This page already shows that profile, and you are not
                // someone to open from a list of your own.
                guard !isViewer, person.pubkey != subject else { return }
                path.append(FollowListRoute(pubkey: person.pubkey))
            },
            onToggleFollow: { follows.toggle(person.pubkey, name: person.name) }
        )
        .onAppear { follows.needProfile(person.pubkey, from: nostrService) }
    }

    private func loadTrust() {
        let feed = FeedService.shared
        // The relay's graph loads lazily; this reads it if nothing has yet.
        webOfTrust = feed.relayTabTrustedPubkeys().union(feed.extendedNetworkPubkeys)
        var rank: [String: Int] = [:]
        for (index, key) in feed.extendedNetworkPubkeys.enumerated() where rank[key] == nil {
            rank[key] = index
        }
        trustRank = rank
    }

    static func shortNpub(_ hex: String) -> String {
        let npub = Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data()) ?? hex
        return String(npub.prefix(16)) + "…"
    }
}

private extension View {
    /// iOS 26 blurs content up into the bar; this page's bar is solid.
    @ViewBuilder
    func solidTopEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

struct FollowListRoute: Hashable {
    let pubkey: String
}

/// The sort chosen on each tab, kept for the rest of the session.
@MainActor
final class FollowListSortMemory {
    static let shared = FollowListSortMemory()
    var sorts: [FollowListTab: FollowListSort] = [:]
}

// MARK: - Row view

struct FollowListRow: View {
    let pubkey: String
    let name: String
    let profile: FeedProfile?
    let followsYou: Bool
    /// nil hides the button (your own row).
    let followState: FollowButtonState?
    let onOpen: () -> Void
    let onToggleFollow: () -> Void
    /// A profile that never arrives stops shimmering after a while.
    @State private var gaveUpWaiting = false
    @State private var shimmer = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The row's tap target. The Follow button is a sibling, never
            // inside it: a Button nested in a Button never gets the tap.
            HStack(alignment: .top, spacing: 12) {
                AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 44, neutralPlaceholder: true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(name)
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if let nip05 = profile?.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.appSystem(size: 11))
                                .foregroundColor(Color.havenVerified)
                                .accessibilityLabel("Verified")
                        }
                        if followsYou {
                            Text("Follows you")
                                .font(.appSystem(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.16)))
                                .fixedSize()
                        }
                    }
                    bio
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)

            if let followState {
                FollowListButton(state: followState, action: onToggleFollow)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .task(id: pubkey) {
            guard profile == nil else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            gaveUpWaiting = true
        }
    }

    /// Always two lines tall, so rows keep one height as profiles land.
    @ViewBuilder
    private var bio: some View {
        if profile == nil && !gaveUpWaiting {
            Text(verbatim: "Loading this person's bio so it can be shown here on two lines")
                .font(.appSystem(size: 13))
                .lineLimit(2, reservesSpace: true)
                .redacted(reason: .placeholder)
                .opacity(shimmer ? 0.5 : 1.0)
                .animation(Motion.shimmer, value: shimmer)
                .onAppear { if Motion.shimmer != nil { shimmer = true } }
                .accessibilityHidden(true)
        } else {
            // Plain text: links in a bio are not tappable here, so the whole
            // row stays one tap target.
            Text(verbatim: FollowListLogic.bioLine(profile?.about) ?? " ")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
    }
}

enum FollowButtonState: Equatable {
    case follow
    case following
    /// Tapped before the follow list loaded; lands once it does.
    case pending(follow: Bool)
}

/// Filled "Follow", outlined "Following". The drawn capsule is 30pt tall; the
/// hit area is at least 44pt.
struct FollowListButton: View {
    let state: FollowButtonState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(filled ? .white : .primary)
                .frame(minWidth: 84, minHeight: 30)
                .background(
                    Capsule().fill(filled ? Color.havenPurple : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(filled ? Color.clear : Color.secondary.opacity(0.45), lineWidth: 1)
                )
                .opacity(isPending ? 0.6 : 1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filled ? "Follow" : "Following")
        .accessibilityHint(filled ? "" : "Unfollows")
    }

    private var filled: Bool {
        switch state {
        case .follow: return true
        case .following: return false
        case .pending(let follow): return !follow
        }
    }

    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    private var label: String { filled ? "Follow" : "Following" }
}

// MARK: - Follow state

/// Watches only the viewer's follow list, so the page redraws for a follow
/// and not for every note the main feed takes in.
@MainActor
final class FollowListFollowWatch: ObservableObject {
    @Published private(set) var followed: [String] = FeedService.shared.followedPubkeys
    /// Taps queued until the follow list loads: pubkey → follow?
    @Published private var queued: [String: Bool] = [:]
    private var cancellable: AnyCancellable?
    private var profileBatch = Set<String>()
    private var profileFlush: DispatchWorkItem?

    init() {
        cancellable = FeedService.shared.$followedPubkeys
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                self.followed = list
                // A queued tap has landed once the list agrees with it.
                let set = Set(list)
                self.queued = self.queued.filter { key, follow in set.contains(key) != follow }
            }
    }

    func state(for pubkey: String) -> FollowButtonState {
        if let follow = queued[pubkey] { return .pending(follow: follow) }
        return followed.contains(pubkey) ? .following : .follow
    }

    /// Changes the follow at once. A refusal leaves the list untouched, so
    /// the button rolls straight back; the banner offers Undo on success.
    func toggle(_ pubkey: String, name: String, offerUndo: Bool = true) {
        let feed = FeedService.shared
        let banner = FollowNotificationManager.shared
        let follow = !followed.contains(pubkey)
        // The list changes now; if the new list cannot be published the feed
        // puts it back and the button follows.
        let failed: () -> Void = {
            banner.add(recipientName: name, kind: .failed(follow ? "Couldn't publish the follow" : "Couldn't publish the unfollow"))
        }
        let result = follow
            ? feed.followUser(pubkey, onPublishFailed: failed)
            : feed.unfollowUser(pubkey, onPublishFailed: failed)
        switch result {
        case .success:
            let undo: (() -> Void)? = offerUndo ? { [weak self] in
                self?.toggle(pubkey, name: name, offerUndo: false)
            } : nil
            banner.add(recipientName: name, kind: follow ? .followed : .unfollowed, undo: undo)
        case .failure(.contactsNotLoaded), .failure(.listUnavailable):
            queued[pubkey] = follow
            banner.addPending(pubkey: pubkey, recipientName: name, follow: follow)
        case .failure(let err):
            banner.add(recipientName: name, kind: .failed(Self.message(err, follow: follow)))
        }
    }

    /// Profiles load in small batches as rows scroll into view.
    func needProfile(_ pubkey: String, from nostr: NostrService) {
        guard nostr.profiles[pubkey] == nil else { return }
        profileBatch.insert(pubkey)
        profileFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.profileBatch.isEmpty else { return }
            nostr.fetchMissingProfiles(for: Array(self.profileBatch))
            self.profileBatch.removeAll()
        }
        profileFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func message(_ err: FeedService.FollowActionError, follow: Bool) -> String {
        switch err {
        case .alreadyFollowing: return follow ? "Already following" : "Unfollow failed"
        case .cannotUnfollowSelf: return follow ? "Follow failed" : "Can't unfollow yourself"
        case .contactsNotLoaded, .listUnavailable:
            return follow ? "Following once your follow list loads…" : "Unfollowing once your follow list loads…"
        }
    }
}
