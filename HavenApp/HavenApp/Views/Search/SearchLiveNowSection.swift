import SwiftUI

/// Live now at the top of Search (Logen, 2026-11-04): people you follow who
/// are on air, with picture, name and stream title; a tap opens the player.
/// Same data and rules as Your space's Live now panel (`LiveNowModel`,
/// `LiveNow.pick`). Asks only while Search's start page is on screen, and
/// draws nothing at all when nobody is live, so Search stays calm.
struct SearchLiveNowSection: View {
    @StateObject private var model = LiveNowModel()
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var feedService = FeedService.shared
    @State private var playing: LiveStream?

    var body: some View {
        let streams = model.streams
        VStack(alignment: .leading, spacing: 10) {
            if !streams.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Live now")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(streams.prefix(LiveNow.maxRows).enumerated()), id: \.element.id) { index, stream in
                        if index > 0 { Divider().padding(.leading, 56) }
                        row(stream)
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(12)
                if streams.count > LiveNow.maxRows {
                    Text("+\(streams.count - LiveNow.maxRows) more live")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        // Empty, it still sits in the start page's stack (it has to, to ask);
        // take back that stack's 24 pt gap so nothing shows.
        .padding(.bottom, streams.isEmpty ? -24 : 0)
        .onAppear {
            model.attach(ConfigService.shared.activeAccountHexPubkey)
            model.start()
        }
        .onDisappear { model.stop() }
        // The follow list can arrive after Search did: look as soon as it does.
        .onChange(of: feedService.followedPubkeys.isEmpty) { _, empty in if !empty { model.refresh() } }
        .sheet(item: $playing) { stream in
            LiveStreamPlayerView(stream: stream)
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
    }

    private func row(_ stream: LiveStream) -> some View {
        let profile = nostrService.profiles[stream.hostPubkey]
        let name = profile?.bestName ?? String(stream.hostPubkey.prefix(8))
        return Button { playing = stream } label: {
            HStack(spacing: 10) {
                AvatarView(url: profile?.pictureURL, pubkey: stream.hostPubkey, size: 34)
                    .overlay(Circle().strokeBorder(Color.red, lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.appSystem(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(stream.title ?? "Live now")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("LIVE")
                    .font(.appSystem(size: 10, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) is live: \(stream.title ?? "stream"). Opens the stream")
    }
}
