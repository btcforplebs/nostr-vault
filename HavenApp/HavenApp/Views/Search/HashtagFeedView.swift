import SwiftUI
import Combine

/// A hashtag's posts: people you follow first, then the rest of your network.
/// Everyone sits behind the same app-wide shield and warning as Global.
struct HashtagFeedView: View {
    let tag: String
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var interests = InterestListService.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HashtagFeedModel
    @State private var showingEveryoneWarning = false
    @State private var showingTrustLock = false
    @State private var followSaving = false
    @State private var showingFollowFailed = false
    @State private var showingProfile: IdentifiableString?
    @State private var showingNote: FeedNote?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom

    init(tag: String) {
        self.tag = tag
        _model = StateObject(wrappedValue: HashtagFeedModel(tag: tag))
    }

    private var everyone: Bool { configService.config.globalShowsEveryone }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    if model.fromFollows.isEmpty && model.fromOthers.isEmpty {
                        emptyState
                    }
                    if !model.fromFollows.isEmpty {
                        sectionHeader("From people you follow")
                        ForEach(model.fromFollows) { note in
                            row(note).onAppear { model.rowAppeared(note, in: .follows) }
                        }
                        if model.loadingOlder == .follows { olderSpinner }
                    }
                    if !model.fromOthers.isEmpty {
                        if !everyone { sectionHeader("More from your network") }
                        ForEach(model.fromOthers) { note in
                            row(note).onAppear { model.rowAppeared(note, in: .others) }
                        }
                        if model.loadingOlder == .others { olderSpinner }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if everyone {
                            configService.config.globalShowsEveryone = false
                            configService.save()
                        } else if TrustScopeLock.isLocked(followCount: feedService.trustLockFollowCount, everyoneIsOn: false) {
                            showingTrustLock = true
                        } else {
                            showingEveryoneWarning = true
                        }
                    } label: {
                        Image(systemName: everyone ? "shield.slash.fill"
                              : TrustScopeLock.isLocked(followCount: feedService.trustLockFollowCount, everyoneIsOn: false)
                              ? "lock.shield.fill" : "checkmark.shield.fill")
                            .foregroundColor(everyone ? .orange : .havenPurple)
                    }
                    .accessibilityLabel(everyone ? "Everyone" : "Web of Trust")
                    .help(everyone ? "Everyone: unfiltered posts. Click for your Web of Trust" : "Web of Trust: people you follow and the people they follow. Click for everyone")
                }
            }
        }
        .hashtagLinks()
        .task {
            interests.refreshIfNeeded()
            restart()
        }
        // Your web changed: the follow list or trust graph arrived after the
        // sheet opens, you followed someone here, or you switched accounts. A count
        // missed a swap that kept the size, so this listens to the web itself.
        .onReceive(TrustPathService.webChanged) { restart() }
        .onChange(of: everyone) { _, _ in restart() }
        .onDisappear { model.stop() }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingEveryoneWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                configService.config.globalShowsEveryone = true
                configService.save()
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
        }
        .sheet(isPresented: $showingTrustLock) {
            TrustScopeLockSheet(followCount: feedService.trustLockFollowCount)
        }
        .alert("Couldn't save", isPresented: $showingFollowFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your relays didn't answer, so your hashtag list wasn't changed. Try again in a moment.")
        }
        .sheet(item: $showingProfile) { profile in
            ProfileView(pubkey: profile.id, onDismiss: { showingProfile = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingNote) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { NoteDetailView(note: $0) }
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
    }

    /// Your own posts count with your follows: you just tagged it, you want to see it.
    private func restart() {
        var follows = Set(feedService.followedPubkeys)
        if !configService.activeAccountHexPubkey.isEmpty { follows.insert(configService.activeAccountHexPubkey) }
        model.start(follows: follows, trust: feedService.globalTrustSet())
    }

    private var isFollowingTag: Bool { interests.isFollowing(tag) }

    /// Big #tag with the Follow button. Followed tags are your interest list
    /// (kind 10015), the same list other Nostr apps read.
    private var header: some View {
        HStack(spacing: 12) {
            Text("#\(tag)")
                .font(.appTitle2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: toggleFollow) {
                HStack(spacing: 6) {
                    Image(systemName: isFollowingTag ? "checkmark" : "plus")
                        .font(.appSystem(size: 12, weight: .semibold))
                    Text(isFollowingTag ? "Following" : "Follow")
                        .font(.appSystem(size: 13, weight: .semibold))
                }
                .foregroundColor(isFollowingTag ? .white : .havenPurple)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isFollowingTag ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(followSaving || configService.activeAccountHexPubkey.isEmpty)
            .accessibilityLabel(isFollowingTag ? "Unfollow #\(tag)" : "Follow #\(tag)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func toggleFollow() {
        let follow = !isFollowingTag
        followSaving = true
        Task {
            let ok = await interests.setFollowing(tag, follow)
            followSaving = false
            if !ok { showingFollowFailed = true }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
            } else {
                Image(systemName: "number").font(.appSystem(size: 28)).foregroundColor(.secondary)
                Text(everyone ? "No posts tagged #\(tag) yet"
                              : "No posts tagged #\(tag) from people you follow or your network yet")
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
        .padding(.top, 60)
    }

    private var olderSpinner: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    private func row(_ note: FeedNote) -> some View {
        FeedNoteRow(
            note: note,
            profile: nostrService.profiles[note.pubkey],
            rowData: FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService),
            onProfile: { showingProfile = IdentifiableString(id: $0) },
            onMedia: { url, urls in showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) },
            showParent: false
        )
        .contentShape(Rectangle())
        .onTapGesture { showingNote = note }
        .padding(.horizontal, 16)
        .onAppear { nostrService.fetchMissingProfiles(for: [note.pubkey]) }
    }
}
