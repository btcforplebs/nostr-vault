import SwiftUI
import Combine

// MARK: - Hashtag feeds

/// `nostrvault://hashtag/<tag>`: what a #hashtag in a post links to.
enum HashtagLink {
    static func url(for tag: String) -> URL? {
        let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "nostrvault://hashtag/\(encoded)")
    }

    static func tag(from url: URL) -> String? {
        guard url.scheme == "nostrvault", url.host == "hashtag" else { return nil }
        let tag = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        return tag.isEmpty ? nil : tag.lowercased()
    }
}

extension View {
    /// Opens a hashtag feed, as a sheet from this view, when a #hashtag link
    /// below it is tapped. Put it on each screen that can present (the root,
    /// a profile, a thread, search): the nearest one handles the tap.
    func hashtagLinks() -> some View {
        modifier(HashtagLinkHandling())
    }
}

private struct HashtagLinkHandling: ViewModifier {
    @State private var shown: IdentifiableString?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let tag = HashtagLink.tag(from: url) {
                    shown = IdentifiableString(id: tag)
                    return .handled
                }
                return .systemAction
            })
            .sheet(item: $shown) { item in
                HashtagFeedView(tag: item.id)
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                    #endif
            }
    }
}
