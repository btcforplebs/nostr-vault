import SwiftUI

/// Live now, a Your space panel: streams (NIP-53) from people you follow that
/// are on air, newest first. A row opens the stream's player. Nobody live is
/// one calm line, not an error. The web's twin is `LiveNow.jsx`.
struct LiveNowPanel: View {
    @ObservedObject var model: LiveNowModel
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var feedService = FeedService.shared
    @State private var playing: LiveStream?

    var body: some View {
        let streams = model.streams
        VStack(alignment: .leading, spacing: 0) {
            if streams.isEmpty {
                Text(model.loaded || feedService.followedPubkeys.isEmpty
                     ? LiveNow.emptyLine(followsSomeone: !feedService.followedPubkeys.isEmpty)
                     : "Looking for live streams...")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(Array(streams.prefix(LiveNow.maxRows).enumerated()), id: \.element.id) { index, stream in
                    if index > 0 { Divider().padding(.leading, 56) }
                    row(stream)
                }
                if streams.count > LiveNow.maxRows {
                    Text("+\(streams.count - LiveNow.maxRows) more live")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(12)
                }
            }
        }
        // SpaceColumn starts and stops `model` (it also feeds the folded strip).
        .sheet(item: $playing) { stream in
            LiveStreamPlayerView(stream: stream)
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
    }

    private func row(_ stream: LiveStream) -> some View {
        let name = nostrService.profiles[stream.hostPubkey]?.bestName ?? String(stream.hostPubkey.prefix(8))
        return Button { playing = stream } label: {
            HStack(spacing: 10) {
                AvatarView(url: nostrService.profiles[stream.hostPubkey]?.pictureURL, pubkey: stream.hostPubkey, size: 34)
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
