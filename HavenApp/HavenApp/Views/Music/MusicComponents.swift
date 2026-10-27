import AVKit
import Combine
import SwiftUI

enum MusicCount {
    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
    static func albums(_ n: Int) -> String { n == 1 ? "1 album" : "\(n) albums" }
    static func minutes(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

/// A page's songs. Tap plays from that song on (or pauses the one
/// playing); long-press shares or opens its artist or album.
struct MusicTrackList: View {
    let tracks: [WavlakeTrack]
    @Binding var sheet: MusicSheet?
    /// Album order: a track number in place of the cover.
    var numbered = false
    /// A song shown tinted, the one a feed card opened this page for.
    var highlightedId: String? = nil
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        // The highlighted song scrolls itself into view (ScrollIntoViewMarker),
        // so it has to exist: a lazy row far down isn't made until the
        // page is scrolled near it.
        if highlightedId != nil {
            VStack(spacing: 4) { rows }
        } else {
            LazyVStack(spacing: 4) { rows }
        }
    }

    private var rows: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
            HStack(spacing: 0) {
                MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying,
                              number: numbered ? offset + 1 : nil)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(player.current?.id == track.id && player.isPlaying ? "Pauses the song" : "Plays the song")
                    .onTapGesture {
                        if player.current?.id == track.id {
                            player.togglePlayPause()
                        } else {
                            player.play(tracks, startAt: offset)
                        }
                    }
                // The same actions as a long-press, in plain sight.
                MusicMoreMenu(label: "More for \(track.title)") {
                    MusicTrackActions(track: track, sheet: $sheet)
                }
            }
            .contextMenu { MusicTrackActions(track: track, sheet: $sheet) }
            .padding(.horizontal, highlightedId == track.id ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(highlightedId == track.id ? Color.havenPurple.opacity(0.15) : Color.clear)
            )
            #if os(iOS)
            .background { if highlightedId == track.id { ScrollIntoViewMarker() } }
            #endif
        }
    }
}

#if os(iOS)
/// Scrolls the scroll view it sits in so it's centred, once, when it
/// appears. For a row inside the feed: a ScrollViewReader in here only
/// reaches scroll views inside it, not the feed's own.
struct ScrollIntoViewMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Marker() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Marker: UIView {
        private var done = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !done else { return }
            // Once the page has laid out around it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scroll() }
        }

        private func scroll() {
            guard !done, window != nil else { return }
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            guard let scroll = view as? UIScrollView else { return }
            done = true
            let inset = scroll.adjustedContentInset
            let rect = convert(bounds, to: scroll)
            let top = -inset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
            let y = min(max(rect.midY - scroll.bounds.height / 2, top), bottom)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
        }
    }
}
#endif

/// Play from the top and Shuffle, plus any extra pill (an artist's Nostr
/// profile). Disabled until there are songs.
struct MusicPlayButtons<Extra: View>: View {
    let tracks: [WavlakeTrack]
    @ViewBuilder let extra: () -> Extra
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        HStack(spacing: 10) {
            MusicPillButton(title: "Play", icon: "play.fill", filled: true) { player.play(tracks) }
            MusicPillButton(title: "Shuffle", icon: "shuffle", filled: false) { player.playShuffled(tracks) }
            extra()
        }
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.5 : 1)
    }
}

struct MusicPillButton: View {
    let title: String
    let icon: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(filled ? .white : .havenPurple)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(filled ? Color.havenPurple : Color.havenPurple.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A song's ⋯: its long-press actions behind a visible button.
struct MusicMoreMenu<Items: View>: View {
    let label: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(label)
        #endif
        .accessibilityLabel(label)
    }
}

/// Go to the playing song's artist or album, for the mini player's and the
/// folded bar's long-press.
struct MusicNowPlayingPageActions: View {
    let track: PlayerTrack

    var body: some View {
        if let song = track.wavlake {
            if let page = MusicFeedState.artistPage(of: song) {
                Button { MusicFeedState.shared.reveal(page) } label: {
                    Label("Go to \(song.artist)", systemImage: "music.mic")
                }
            }
            if let page = MusicFeedState.albumPage(of: song) {
                Button { MusicFeedState.shared.reveal(page) } label: {
                    Label(song.albumTitle.map { "Go to \($0)" } ?? "Go to album", systemImage: "square.stack")
                }
            }
        }
    }
}

struct MusicBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.appSystem(size: 15, weight: .semibold))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.havenPurple)
    }
}

struct MusicSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            accessory
            Text(title).font(.appSystem(size: 18, weight: .bold)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// An album or artist to open: square cover, or a round picture for artists.
struct MusicCollectionTile: View {
    let title: String
    let subtitle: String
    let art: URL?
    let round: Bool
    var size: CGFloat = 110
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                MusicArtwork(url: art, size: size)
                    .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
                Text(title).font(.appSystem(size: 13, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(.appSystem(size: 11)).foregroundColor(.secondary)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(round ? "Opens the artist" : "Opens the album")
    }
}

struct MusicRetryMessage: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        Text(text)
            .font(.appSystem(size: 14))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture(perform: retry)
    }
}

struct MusicTrackRow: View {
    let track: WavlakeTrack
    let isCurrent: Bool
    let isPlaying: Bool
    /// Album order: the track number shows instead of the cover.
    var number: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        Image(systemName: isPlaying ? "waveform" : "play.fill")
                            .font(.appSystem(size: 14, weight: .bold))
                            .foregroundColor(.havenPurple)
                    } else {
                        Text("\(number)")
                            .font(.appSystem(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 28, height: 40)
            } else {
            ZStack {
                MusicArtwork(url: track.artworkURL, size: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)).frame(width: 48, height: 48)
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.appSystem(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(isCurrent ? .havenPurple : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let sats = track.sats, sats > 0 {
                Label("\(sats.formatted())", systemImage: "bolt.fill")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .labelStyle(.titleAndIcon)
            }
            if let duration = track.duration, duration > 0 {
                Text(MusicTime.format(Double(duration)))
                    .font(.appSystem(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MusicArtwork: View {
    let url: URL?
    let size: CGFloat
    /// A load cut off by the page swapping in (opening an artist from the
    /// player switches tab and feed at once) fails for good; try again.
    @State private var retries = 0

    var body: some View {
        Group {
            if let url = MediaCacheService.offMeshURL(url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil, retries < 2 {
                        placeholder.task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            retries += 1
                        }
                    } else {
                        placeholder
                    }
                }
                .id(retries)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note").foregroundColor(.secondary)
        }
    }
}

enum MusicTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
