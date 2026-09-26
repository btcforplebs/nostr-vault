import SwiftUI
import AVFoundation

/// Reels: full-screen videos, one per page, swiped vertically.
///
/// Only the page on screen plays. Its neighbours build their players ahead of
/// time so a swipe lands on a video that is already buffering — the player
/// cache holds three, which is exactly previous, current and next.
struct ReelsFeedView: View {
    @ObservedObject private var service = ReelsFeedService.shared
    @ObservedObject var feedService: FeedService
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    let onProfile: (String) -> Void
    let onReply: (FeedNote) -> Void
    let onOpenNote: (FeedNote) -> Void
    let onLike: (FeedNote) -> Void
    let onShowGlobal: () -> Void
    /// A sheet (reply, profile, thread) is over the feed. The reel under it
    /// must go quiet: a sheet does not end the page's appearance.
    var isCovered: Bool = false

    @State private var currentId: String?
    /// Sound follows the viewer from reel to reel and across launches.
    @AppStorage("reelsMuted") private var isMuted = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if service.reels.isEmpty {
                    if service.isLoading || service.isLoadingMore
                        || (service.followSetIsEmpty && feedService.isLoadingContacts) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        emptyState
                    }
                } else {
                    pager(insets: chromeInsets(geo.safeAreaInsets))
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            service.loadIfNeeded()
            if currentId == nil { currentId = service.reels.first?.id }
        }
        // Pages only mute themselves; the session goes back to mixing, so
        // other apps' music can resume, once the whole feed is gone.
        .onDisappear {
            if VideoPlayerCache.shared.activeFullScreenURL == nil {
                AudioSessionManager.shared.enableMixingWithOthers()
            }
        }
        .onChange(of: service.reels) { _, reels in
            if currentId == nil || !reels.contains(where: { $0.id == currentId }) {
                currentId = reels.first?.id
            }
            nostrService.fetchMissingProfiles(for: Array(Set(reels.prefix(60).map(\.note.pubkey))))
        }
        // At launch the follow set can land after this view asked for it;
        // "you aren't following anyone" must not outlive the contact load.
        .onChange(of: feedService.followedPubkeys.isEmpty) { _, isEmpty in
            if !isEmpty && service.followSetIsEmpty && service.scope == .following {
                service.refresh()
            }
        }
        // A profile sheet can block its author; drop their reels on the way back.
        .onChange(of: isCovered) { _, covered in
            if !covered { service.pruneBlocked() }
        }
        .onChange(of: currentId) { _, id in
            guard let id else { return }
            service.didShow(reelId: id)
            if let index = service.reels.firstIndex(where: { $0.id == id }), index >= service.reels.count - 3 {
                service.loadMore()
            }
        }
    }

    /// The page draws edge to edge; its chrome clears the status bar, the
    /// home indicator and the floating tab bar.
    private func chromeInsets(_ safeArea: EdgeInsets) -> EdgeInsets {
        var insets = safeArea
        insets.bottom += tabBarHeight
        return insets
    }

    private func pager(insets: EdgeInsets) -> some View {
        let reels = service.reels
        let currentIndex = reels.firstIndex { $0.id == currentId } ?? 0
        return ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(reels.enumerated()), id: \.element.id) { index, reel in
                    ReelPageView(
                        reel: reel,
                        profile: nostrService.profiles[reel.note.pubkey],
                        isActive: index == currentIndex && scenePhase == .active && !isCovered,
                        shouldPrepare: abs(index - currentIndex) <= 1,
                        isLiked: feedService.likedEventIds.contains(reel.id),
                        insets: insets,
                        isMuted: $isMuted,
                        onProfile: { onProfile(reel.note.pubkey) },
                        onReply: { onReply(reel.note) },
                        onOpenNote: { onOpenNote(reel.note) },
                        onLike: { onLike(reel.note) }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                }

                if service.isLoadingMore {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentId)
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: service.loadFailed ? "wifi.slash" : "play.rectangle.on.rectangle")
                .font(.appSystem(size: 34))
                .foregroundColor(.white.opacity(0.7))
            Text(emptyTitle)
                .font(.appSystem(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(emptyMessage)
                .font(.appSystem(size: 13))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if service.followSetIsEmpty || (service.scope == .following && !service.loadFailed) {
                Button("Show everyone's videos") { onShowGlobal() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurpleLight)
                    .padding(.top, 4)
            } else {
                Button("Try again") { service.refresh() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurpleLight)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
    }

    private var emptyTitle: String {
        if service.followSetIsEmpty { return "You aren't following anyone yet" }
        if service.loadFailed { return "Could not reach any relay" }
        return service.scope == .following ? "No videos from your follows" : "No videos found"
    }

    private var emptyMessage: String {
        if service.followSetIsEmpty { return "Switch to Global to see everyone's videos." }
        if service.loadFailed { return "Reels come from relays, so this one needs a connection." }
        return service.scope == .following
            ? "Nobody you follow has posted a video recently."
            : "Nothing playable came back from your relays."
    }
}

// MARK: - One page

private struct ReelPageView: View {
    let reel: Reel
    let profile: FeedProfile?
    let isActive: Bool
    let shouldPrepare: Bool
    let isLiked: Bool
    let insets: EdgeInsets
    @Binding var isMuted: Bool
    let onProfile: () -> Void
    let onReply: () -> Void
    let onOpenNote: () -> Void
    let onLike: () -> Void

    @ObservedObject private var failures = VideoPlaybackFailures.shared
    @State private var player: AVPlayer?
    @State private var isPreparing = false
    /// `isActive`/`shouldPrepare` mirrored into state. Player setup is async,
    /// and a `let` read after the await is the value from when it started —
    /// @State reads the page's current value.
    @State private var wantsPlay = false
    @State private var wantsWarm = false
    @State private var isOnScreen = false
    @State private var hasFrame = false
    @State private var learnedAspect: CGFloat?
    @State private var poster: PlatformImage?
    /// Paused by a tap, as opposed to paused because it is off screen.
    @State private var userPaused = false
    @State private var heartBurst = false
    @State private var captionExpanded = false

    private var authorName: String {
        profile?.bestName ?? CondensedNoteLine.shortKey(reel.note.pubkey)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                video(in: geo.size)

                // Tap to pause, double-tap to like. Sits under the chrome so
                // the buttons still get their own taps.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { likeWithBurst() }
                    .onTapGesture { togglePause() }

                if userPaused {
                    Image(systemName: "play.fill")
                        .font(.appSystem(size: 54))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if heartBurst {
                    Image(systemName: "heart.fill")
                        .font(.appSystem(size: 96))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.35), radius: 10)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if failures.hasFailed(reel.videoURL) {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.appSystem(size: 28))
                        Text("This video can't be played")
                            .font(.appSystem(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .allowsHitTesting(false)
                }

                chrome
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear {
            isOnScreen = true
            wantsPlay = isActive
            wantsWarm = shouldPrepare
            loadPoster()
            syncPlayback()
        }
        .onDisappear { release() }
        .onChange(of: isActive) { _, active in
            wantsPlay = active
            syncPlayback()
        }
        .onChange(of: shouldPrepare) { _, warm in
            wantsWarm = warm
            syncPlayback()
        }
        .onChange(of: isMuted) { _, muted in
            guard isActive, let player else { return }
            VideoPlaybackService.shared.setMuted(muted, on: player)
            // Switching the session category stops the players in it; pick
            // the reel back up unless the viewer had paused it.
            applyState(to: player)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video by \(authorName)")
    }

    // MARK: Video

    /// Fill the screen when the video is close to the screen's shape (a
    /// portrait clip on a phone loses a sliver at the sides); otherwise fit, so
    /// a landscape clip or a phone video on an iPad is not cropped to a strip.
    private func gravity(for size: CGSize) -> AVLayerVideoGravity {
        guard let aspect = learnedAspect ?? reel.aspectRatio, size.height > 0 else { return .resizeAspect }
        let screen = size.width / size.height
        let mismatch = max(aspect / screen, screen / aspect)
        return mismatch <= 1.3 ? .resizeAspectFill : .resizeAspect
    }

    @ViewBuilder
    private func video(in size: CGSize) -> some View {
        let gravity = gravity(for: size)
        ZStack {
            if let poster, !hasFrame {
                Image(platformImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: gravity == .resizeAspectFill ? .fill : .fit)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            if let player {
                InlinePlayerLayer(player: player, videoGravity: gravity)
                    .frame(width: size.width, height: size.height)
                    .opacity(hasFrame ? 1 : 0)
                    .allowsHitTesting(false)
                    .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                        if status == .playing && !hasFrame {
                            withAnimation(Motion.fade) { hasFrame = true }
                        }
                    }
                    .onReceive(player.publisher(for: \.currentItem?.presentationSize)) { size in
                        if let size, size.width > 0, size.height > 0 {
                            learnedAspect = size.width / size.height
                        }
                    }
            }

            if !hasFrame && isActive && poster == nil && !failures.hasFailed(reel.videoURL) {
                ProgressView().tint(.white)
            }
        }
    }

    private func syncPlayback() {
        if wantsPlay || wantsWarm, player == nil, !isPreparing {
            isPreparing = true
            Task { @MainActor in
                // The intent sets the audio session. With sound on, an
                // `.inline` neighbour warming up would drop the session back
                // to mixing and silence the reel that is playing.
                let prepared = await VideoPlaybackService.shared.preparedPlayer(
                    for: reel.videoURL, mimeHint: reel.mimeType, intent: isMuted ? .inline : .fullScreen
                )
                isPreparing = false
                // The page may have scrolled away, or out of the warm window,
                // while the player was being built.
                guard isOnScreen, wantsPlay || wantsWarm else {
                    prepared.pause()
                    prepared.isMuted = true
                    return
                }
                player = prepared
                applyState(to: prepared)
            }
            return
        }
        if let player { applyState(to: player) }
    }

    private func applyState(to player: AVPlayer) {
        let isActive = wantsPlay
        if isActive && !userPaused {
            VideoPlaybackService.shared.setMuted(isMuted, on: player)
            player.play()
        } else {
            player.pause()
            if !isActive {
                // Coming back to a reel starts it over, the way a swipe feed
                // reads — and a tap-pause does not follow it off screen.
                player.seek(to: .zero)
                userPaused = false
                // Only the playing reel may hold the audio session.
                if !player.isMuted { player.isMuted = true }
            }
        }
    }

    private func release() {
        isOnScreen = false
        guard let player else { return }
        player.pause()
        // Mute the player only. Switching the session to mixing here would cut
        // the sound of the reel that just scrolled in; the feed hands audio
        // back when it leaves the screen.
        player.isMuted = true
        self.player = nil
        hasFrame = false
    }

    private func togglePause() {
        guard let player else { return }
        withAnimation(Motion.control) { userPaused.toggle() }
        if userPaused { player.pause() } else { player.play() }
    }

    private func likeWithBurst() {
        if !isLiked { onLike() }
        withAnimation(Motion.pop) { heartBurst = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(Motion.fade) { heartBurst = false }
        }
    }

    private func loadPoster() {
        guard poster == nil else { return }
        let reel = reel
        Task {
            let image: PlatformImage?
            if let posterURL = reel.posterURL,
               let (data, _) = try? await URLSession.shared.data(from: posterURL),
               let decoded = PlatformImage(data: data) {
                image = decoded
            } else {
                image = await MediaCacheService.shared.generateThumbnail(
                    for: reel.videoURL, mimeType: reel.mimeType, allowFullDownload: false
                )
            }
            await MainActor.run {
                poster = image
                if learnedAspect == nil, let size = image?.size, size.width > 0, size.height > 0 {
                    learnedAspect = size.width / size.height
                }
            }
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            // Keeps the feed picker legible over a bright first frame.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: insets.top + 70)
                .allowsHitTesting(false)

            Spacer(minLength: 0)

            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 12) {
                        details
                        Spacer(minLength: 0)
                        actionRail
                    }
                    .padding(.horizontal, 14)

                    if let player {
                        VideoScrubber(player: player)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, insets.bottom + 6)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onProfile) {
                HStack(spacing: 8) {
                    AvatarView(url: profile?.pictureURL, pubkey: reel.note.pubkey, size: 32)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                    Text(authorName)
                        .font(.appSystem(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("· " + CondensedNoteLine.relativeTime(reel.note.createdAt))
                        .font(.appSystem(size: 13))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(authorName)'s profile")

            if let title = reel.title {
                Text(title)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .lineLimit(2)
            }

            if !reel.caption.isEmpty {
                Text(reel.caption)
                    .font(.appSystem(size: 14))
                    .lineLimit(captionExpanded ? 12 : 2)
                    .multilineTextAlignment(.leading)
                    .onTapGesture { withAnimation(Motion.toggle) { captionExpanded.toggle() } }
            }
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.4), radius: 3)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var actionRail: some View {
        VStack(spacing: 18) {
            railButton(
                icon: isLiked ? "heart.fill" : "heart",
                tint: isLiked ? .red : .white,
                label: isLiked ? "Liked" : "Like"
            ) { if !isLiked { onLike() } }

            railButton(icon: "bubble.right", label: "Reply", action: onReply)

            railButton(icon: "text.bubble", label: "Open thread", action: onOpenNote)

            ShareLink(item: URL(string: "https://mynostrspace.com/thread/\(reel.note.nevent)")!) {
                railIcon("square.and.arrow.up", tint: .white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")

            railButton(
                icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: isMuted ? "Unmute" : "Mute"
            ) { isMuted.toggle() }
        }
        .padding(.bottom, 4)
    }

    private func railButton(icon: String, tint: Color = .white, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { railIcon(icon, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func railIcon(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.appSystem(size: 24, weight: .semibold))
            .foregroundColor(tint)
            .shadow(color: .black.opacity(0.45), radius: 4)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
