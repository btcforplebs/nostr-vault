import SwiftUI

// MARK: - LiveAvatarRing

/// A red ring on the profile picture of someone who is live right now, and a
/// tap on it that opens their stream instead of whatever the avatar's row does.
/// Off the air, the avatar is left exactly as it was: no ring, no tap.
struct LiveAvatarRing: ViewModifier {
    let pubkey: String
    let size: CGFloat

    @ObservedObject private var live = LiveStatusService.shared
    @Environment(\.liveAvatarOpensStream) private var opensStream
    @State private var playing: LiveStream?

    func body(content: Content) -> some View {
        let isLive = live.liveHosts.contains(pubkey)
        let tapOpens = isLive && opensStream
        content
            .overlay {
                if isLive {
                    Circle()
                        .strokeBorder(Color.red, lineWidth: max(1.5, size * 0.06))
                        .frame(width: size, height: size)
                        .accessibilityHidden(true)
                }
            }
            // High priority so the tap wins over a row's Button or link; the
            // `.subviews` mask turns it off entirely when nobody is live.
            .highPriorityGesture(
                TapGesture().onEnded { playing = live.stream(hostedBy: pubkey) },
                including: tapOpens ? .all : .subviews
            )
            .accessibilityAddTraits(tapOpens ? .isButton : [])
            .accessibilityHint(tapOpens ? Text("Live now. Opens their stream") : Text(""))
            .onAppear { live.watch(pubkey) }
            .onChange(of: pubkey) { _, new in live.watch(new) }
            .sheet(item: $playing) { stream in
                LiveStreamPlayerView(stream: stream)
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
            }
    }
}

extension EnvironmentValues {
    /// Off inside a live player: the host's avatar there still shows the ring,
    /// but a tap must not stack a second player on the one already playing.
    @Entry var liveAvatarOpensStream = true
}
