import SwiftUI

/// The pictures in a Vault-list line, as a tight row of small squares under
/// its words. Three at most; the last one counts the rest. A tap opens the
/// media viewer on that picture, with the line's others there to swipe.
struct VaultActivityThumbnails: View {
    let urls: [URL]
    var onTap: ((URL, [URL]) -> Void)? = nil

    static let side: CGFloat = 56
    private static let shown = 3

    var body: some View {
        let visible = Array(urls.prefix(Self.shown))
        let hidden = urls.count - visible.count
        HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, url in
                FeedMediaView(url: url, onTap: onTap.map { tap in { tap(url, urls) } }, isThumbnail: true)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if hidden > 0, index == visible.count - 1 {
                            ZStack {
                                Color.black.opacity(0.45)
                                Text("+\(hidden)")
                                    .font(.appSystem(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(urls.count == 1 ? "1 picture" : "\(urls.count) pictures")
    }
}
