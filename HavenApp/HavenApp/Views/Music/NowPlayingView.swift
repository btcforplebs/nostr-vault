import AVKit
import Combine
import SwiftUI

/// Full player: the cover (or Up Next) over a blur of it, the song with its
/// artist and album as links into the Music feed, scrubber, shuffle /
/// previous / play / next / repeat, and AirPlay, Up Next and more along
/// the bottom.
/// What opening the mini player shows: a minimized live stream pops back
/// out into its full window (video, chat and all) and keeps playing; a song
/// opens the music player.
struct PlayerSheet: View {
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        if player.current?.isLive == true, let stream = player.liveStream {
            // The window shows the mini player's own video, so the stream
            // plays straight through opening it and swiping it away.
            LiveStreamPlayerView(stream: stream)
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        } else {
            NowPlayingView()
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var sheet: MusicSheet?
    @State private var showingQueue = false

    private static let artSize: CGFloat = 280

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            if let track = player.current {
                Group {
                    if showingQueue {
                        upNext
                    } else {
                        MusicArtwork(url: track.artworkURL, size: Self.artSize)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: Self.artSize)
                .transition(.opacity)

                titles(track)

                if !track.isLive { scrubber }

                transport(track)

                pageButtons(track)

                Spacer(minLength: 0)

                bottomBar(track)
            } else {
                Text("Nothing playing").foregroundColor(.secondary)
                    .onAppear { dismiss() }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background { backdrop }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 640)
        #endif
        .presentationDetents([.large])
        .modifier(MusicSheetHost(sheet: $sheet))
    }

    // MARK: Pieces

    /// The cover, blown up and blurred under a material, so the player
    /// takes on the song's colours and text stays readable in light and dark.
    private var backdrop: some View {
        ZStack {
            if let url = MediaCacheService.offMeshURL(player.current?.artworkURL) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .blur(radius: 50)
                .opacity(0.8)
            }
            Rectangle().fill(.regularMaterial)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Title, then the artist and album, each opening its page.
    private func titles(_ track: PlayerTrack) -> some View {
        VStack(spacing: 4) {
            if track.isLive { LiveBadge() }
            Text(track.title).font(.appSystem(size: 22, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
            if let song = track.wavlake, let page = MusicFeedState.artistPage(of: song) {
                linkText(track.artist, size: 16, weight: .semibold, hint: "Opens the artist") { go(page) }
            } else {
                Text(track.artist).font(.appSystem(size: 16)).foregroundColor(.secondary)
            }
            if let song = track.wavlake, let album = song.albumTitle, album != track.title,
               let page = MusicFeedState.albumPage(of: song) {
                linkText(album, size: 13, weight: .regular, hint: "Opens the album") { go(page) }
            }
        }
        .padding(.horizontal, 24)
    }

    private func linkText(_ text: String, size: CGFloat, weight: Font.Weight, hint: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                Image(systemName: "chevron.right").font(.appSystem(size: size - 4, weight: .semibold))
            }
            .font(.appSystem(size: size, weight: weight))
            .foregroundColor(.havenPurple)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.elapsed },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .tint(.havenPurple)
            HStack {
                Text(MusicTime.format(scrubbing ?? player.elapsed))
                Spacer()
                Text(MusicTime.format(player.duration))
            }
            .font(.appSystem(size: 12).monospacedDigit())
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
    }

    /// Shuffle and repeat flank the usual three; live has only play/pause.
    private func transport(_ track: PlayerTrack) -> some View {
        HStack(spacing: 0) {
            modeButton(icon: "shuffle", isOn: player.isShuffled, label: "Shuffle",
                       value: player.isShuffled ? "On" : "Off", action: player.toggleShuffle)
                .opacity(track.isLive ? 0 : 1)
                .disabled(track.isLive)
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.appSystem(size: 26))
            }
            .opacity(track.isLive ? 0 : 1)
            .disabled(track.isLive)
            .accessibilityLabel("Previous")
            Spacer()
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.appSystem(size: 64))
                    .foregroundColor(.havenPurple)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.appSystem(size: 26))
            }
            .disabled(!player.hasNext)
            .opacity(track.isLive ? 0 : (player.hasNext ? 1 : 0.35))
            .accessibilityLabel("Next")
            Spacer()
            modeButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.repeatMode != .off,
                       label: "Repeat", value: repeatValue, action: player.cycleRepeat)
                .opacity(track.isLive ? 0 : 1)
                .disabled(track.isLive)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
    }

    private var repeatValue: String {
        switch player.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "This song"
        }
    }

    /// Shuffle or repeat: purple on a soft purple disc when on.
    private func modeButton(icon: String, isOn: Bool, label: String, value: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.appSystem(size: 17, weight: .semibold))
                .foregroundColor(isOn ? .havenPurple : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.havenPurple.opacity(isOn ? 0.18 : 0)))
                .contentShape(Circle())
                .animation(Motion.toggle, value: isOn)
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// Where a song leads: its artist and album pages, and Share. A live
    /// stream offers its video and host.
    @ViewBuilder
    private func pageButtons(_ track: PlayerTrack) -> some View {
        HStack(spacing: 10) {
            if let song = track.wavlake {
                if let page = MusicFeedState.artistPage(of: song) {
                    actionButton("Artist", icon: "music.mic") { go(page) }
                }
                if let page = MusicFeedState.albumPage(of: song) {
                    actionButton("Album", icon: "square.stack") { go(page) }
                }
                actionButton("Share", icon: "square.and.arrow.up") {
                    sheet = .share(WavlakeLink.shareText(for: song))
                }
            } else if let host = track.hostPubkey {
                if let stream = player.liveStream {
                    actionButton("Watch", icon: "play.rectangle") { sheet = .live(stream) }
                }
                actionButton("Host", icon: "person.crop.circle") { sheet = .profile(host) }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// AirPlay, Up Next, and the song's other actions.
    private func bottomBar(_ track: PlayerTrack) -> some View {
        HStack {
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            Spacer()
            if !track.isLive {
                Button {
                    withAnimation(Motion.toggle) { showingQueue.toggle() }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.appSystem(size: 18, weight: .semibold))
                        .foregroundColor(showingQueue ? .havenPurple : .secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.havenPurple.opacity(showingQueue ? 0.18 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Up Next")
                .accessibilityValue(showingQueue ? "Showing" : "Hidden")
                Spacer()
            }
            if let song = track.wavlake {
                MusicMoreMenu(label: "More for \(song.title)") {
                    // Artist and Album are buttons right above.
                    MusicTrackActions(track: song, sheet: $sheet, opensPages: false)
                }
                .frame(width: 44, height: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 28)
    }

    /// The songs after this one; tap one to play it now.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.appSystem(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if player.isShuffled {
                    Label("Shuffled", systemImage: "shuffle").font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            let upcoming = Array(player.upNext.enumerated())
            if upcoming.isEmpty {
                Text(player.repeatMode == .all ? "The queue starts over after this song."
                                               : "Nothing after this song.")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(upcoming, id: \.element.id) { offset, item in
                            Button { player.jump(to: player.index + 1 + offset) } label: {
                                HStack(spacing: 10) {
                                    MusicArtwork(url: item.artworkURL, size: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                                        Text(item.artist).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if let duration = item.duration, duration > 0 {
                                        Text(MusicTime.format(Double(duration)))
                                            .font(.appSystem(size: 12).monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays this song now")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    /// Closes the player and opens the page in the Music feed. The page
    /// opens once the sheet is on its way out, so the switch to the feed
    /// tab doesn't happen under it.
    private func go(_ page: MusicFeedState.Page) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            MusicFeedState.shared.reveal(page)
        }
    }
}

/// The system AirPlay / output picker, for sending music to a speaker.
#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = UIColor(Color.havenPurple)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif
