import SwiftUI

struct IdentifiableURL: Identifiable {
    let id = UUID()
    /// The tapped URL — the page the viewer opens on.
    let url: URL
    /// The full set of media in the note this URL came from, in display order.
    /// Defaults to just `[url]` so single-media call sites are unchanged.
    let allURLs: [URL]

    init(url: URL, allURLs: [URL]? = nil) {
        self.url = url
        self.allURLs = (allURLs?.isEmpty == false ? allURLs! : [url])
    }
}

/// Full-screen, swipeable viewer for a note's media. Opens on `selected` and pages
/// horizontally across `urls`, hosting one `FeedMediaViewer` per page (which already
/// yields horizontal drags to a parent `TabView` when not zoomed). On macOS — where
/// `PageTabViewStyle` is unavailable — it falls back to the single tapped item.
struct FeedMediaPager: View {
    let urls: [URL]
    let selected: URL
    var onDismiss: (() -> Void)? = nil
    /// The page now showing, so the zoom can close into that photo's spot.
    var onPage: ((URL) -> Void)? = nil

    @State private var selection: URL
    @Environment(\.mediaZoomPresented) private var zoomPresented

    init(urls: [URL], selected: URL, onDismiss: (() -> Void)? = nil, onPage: ((URL) -> Void)? = nil) {
        self.urls = urls.isEmpty ? [selected] : urls
        self.selected = selected
        self.onDismiss = onDismiss
        self.onPage = onPage
        _selection = State(initialValue: selected)
    }

    var body: some View {
        #if os(iOS)
        if urls.count <= 1 {
            FeedMediaViewer(url: selected, onDismiss: onDismiss)
        } else {
            ZStack {
                // Each page draws its own black, which fades as it is pulled
                // away; a fixed black here would hide the post behind it.
                if !zoomPresented { Color.black.ignoresSafeArea() }
                TabView(selection: $selection) {
                    ForEach(urls, id: \.absoluteString) { url in
                        FeedMediaViewer(url: url, enableDragDismiss: true, onDismiss: onDismiss)
                            .tag(url)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                // A PageTabViewStyle TabView needs a definite size or it collapses
                // (renders as a small square and stops paging). Fill the screen like
                // MediaGalleryViewer's pager does.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onChange(of: selection) { _, page in onPage?(page) }
            }
        }
        #else
        FeedMediaViewer(url: selected, onDismiss: onDismiss)
        #endif
    }
}
