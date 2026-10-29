import SwiftUI

/// The ••• menu on a live stream: sharing first (a note, the link, the
/// streamer's profile), then the way out to the web, then report and block.
struct LiveStreamMoreMenu: View {
    let stream: LiveStream
    let hostName: String
    var onShareAsNote: () -> Void
    var onShareProfile: () -> Void
    var onReport: () -> Void
    var onBlock: () -> Void

    private var naddr: String? {
        LiveStreamShare.naddr(authorPubkey: stream.authorPubkey, identifier: stream.identifier,
                              relays: stream.chatRelays)
    }
    private var link: URL? { naddr.flatMap(LiveStreamShare.link(naddr:)) }

    var body: some View {
        Menu {
            Button(action: onShareAsNote) {
                Label("Share as a note", systemImage: "square.and.pencil")
            }
            if let link {
                ShareLink(item: link, subject: Text(stream.title ?? "Live stream"),
                          message: Text(stream.title ?? "Live on Nostr")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    PlatformClipboard.copy(link.absoluteString)
                    ActionToastManager.shared.show(icon: "link", message: "Link copied")
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
            Button(action: onShareProfile) {
                Label("Share \(hostName)'s profile", systemImage: "person.crop.circle")
            }
            if let web = stream.webLink {
                Divider()
                OpenInWebButton(link: web)
            }
            Divider()
            Button(action: onReport) {
                Label("Report stream", systemImage: "flag")
            }
            Button(role: .destructive, action: onBlock) {
                Label("Block host", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.appSystem(size: 16))
                .foregroundColor(.havenPurple)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        // .borderlessButton flattens the label's tint on the Mac.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("More")
        #else
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .accessibilityLabel("More")
    }
}

/// Follow / Following beside the streamer's name. Hidden on your own stream.
struct LiveHostFollowButton: View {
    let pubkey: String
    let name: String

    @ObservedObject private var feed = FeedService.shared
    @ObservedObject private var config = ConfigService.shared

    private var isFollowing: Bool { feed.followedPubkeys.contains(pubkey) }

    var body: some View {
        if pubkey != config.activeAccountHexPubkey {
            Button {
                FollowActions.toggle(pubkey, name: name, isFollowing: isFollowing)
            } label: {
                Text(isFollowing ? "Following" : "Follow")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(isFollowing ? .secondary : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isFollowing ? Color.controlBackgroundColor : Color.havenPurple)
                    )
                    .overlay(
                        Capsule().stroke(Color.platformSeparator, lineWidth: isFollowing ? 0.5 : 0)
                    )
                    // A 44 pt target around a compact pill.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(isFollowing ? "Unfollow \(name)" : "Follow \(name)")
        }
    }
}
