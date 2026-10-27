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

/// A song's artist's Nostr key. Rankings and search leave it off the song,
/// so it comes from an artist already seen, else from Wavlake's artist page.
/// Each artist is looked up once a launch, a "no key" answer included.
@MainActor
enum MusicArtistKey {
    private static var looked: [String: String?] = [:]

    static func npub(for track: WavlakeTrack) async -> String? {
        if let npub = track.artistNpub { return npub }
        guard let id = track.artistId else { return nil }
        if let known = MusicFeedState.shared.knownArtists.first(where: { $0.id == id && $0.npub != nil }) {
            return known.npub
        }
        if let answer = looked[id] { return answer }
        do {
            let npub = try await WavlakeAPI.artist(id)?.npub
            looked[id] = npub
            return npub
        } catch {
            // Offline or cancelled: ask again next time.
            return nil
        }
    }

    static func hex(for track: WavlakeTrack) async -> String? {
        await npub(for: track).flatMap(MusicSheet.hex(fromNpub:))
    }

    /// Opens the composer with the song, the artist mentioned as
    /// `nostr:npub…` (which the composer posts with a `p` tag) whenever they
    /// have a key. Waits at most a few seconds for Wavlake, then shares
    /// without the mention rather than leave the tap hanging.
    static func share(_ track: WavlakeTrack, into sheet: Binding<MusicSheet?>) {
        Task {
            var song = track
            song.artistNpub = await withTaskGroup(of: String?.self) { group in
                group.addTask { await npub(for: track) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let hex = song.artistNpub.flatMap(MusicSheet.hex(fromNpub:)) {
                // So the composer can show the artist's name, not a key.
                NostrService.shared.fetchMissingProfiles(for: [hex])
            }
            sheet.wrappedValue = .share(WavlakeLink.shareText(for: song))
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
        Button { MusicArtistKey.share(track, into: $sheet) } label: {
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
