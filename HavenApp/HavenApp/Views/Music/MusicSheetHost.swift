import AVKit
import Combine
import SwiftUI

// MARK: - Sharing, artists, live

/// The two places a song leads: a post sharing it, or the artist's Nostr
/// profile (which carries Follow and Zap).
enum MusicSheet: Identifiable {
    case share(String)
    case profile(String)
    case live(LiveStream)

    var id: String {
        switch self {
        case .share(let text): return "share:\(text)"
        case .profile(let hex): return "profile:\(hex)"
        case .live(let stream): return "live:\(stream.id)"
        }
    }

    static func hex(fromNpub npub: String) -> String? {
        guard let decoded = Bech32.decode(npub), decoded.hrp == "npub" else { return nil }
        return decoded.hexString
    }
}

struct MusicSheetHost: ViewModifier {
    @Binding var sheet: MusicSheet?
    @EnvironmentObject private var nostrService: NostrService
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var relayManager: RelayProcessManager

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { item in
            switch item {
            case .share(let text):
                ComposeView(onDismiss: { sheet = nil }, replyTo: nil, quoteTo: nil, initialContent: text, restoredDraftId: nil)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .environmentObject(relayManager)
            case .live(let stream):
                LiveStreamPlayerView(stream: stream)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            case .profile(let hex):
                ProfileView(pubkey: hex, onDismiss: { sheet = nil })
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                    #endif
            }
        }
    }
}

/// Long-press actions on a song.
struct MusicTrackActions: View {
    let track: WavlakeTrack
    @Binding var sheet: MusicSheet?
    /// Go to artist / album. Off where the caller offers its own way there.
    var opensPages = true

    var body: some View {
        if opensPages {
            let feed = MusicFeedState.shared
            if let page = MusicFeedState.artistPage(of: track), feed.showingArtistId != track.artistId {
                Button { feed.reveal(page) } label: {
                    Label("Go to \(track.artist)", systemImage: "music.mic")
                }
            }
            if let page = MusicFeedState.albumPage(of: track), feed.showingAlbumId != track.albumId {
                Button { feed.reveal(page) } label: {
                    Label(track.albumTitle.map { "Go to \($0)" } ?? "Go to album", systemImage: "square.stack")
                }
            }
        }
        Button { sheet = .share(WavlakeLink.shareText(for: track)) } label: {
            Label("Share to Nostr", systemImage: "square.and.arrow.up")
        }
        if let hex = track.artistNpub.flatMap(MusicSheet.hex(fromNpub:)) {
            Button { sheet = .profile(hex) } label: {
                Label("\(track.artist) on Nostr", systemImage: "person.crop.circle")
            }
        }
        if let page = track.pageURL {
            Button { PlatformURL.open(page) } label: {
                Label("Open on Wavlake", systemImage: "safari")
            }
        }
    }
}
