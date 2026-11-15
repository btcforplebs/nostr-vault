import SwiftUI

struct IdentifiableURL: Identifiable {
    let id = UUID()
    /// The tapped URL — the page the viewer opens on.
    let url: URL
    /// The full set of media in the note this URL came from, in display order.
    /// Defaults to just `[url]` so single-media call sites are unchanged.
    let allURLs: [URL]
    /// What the opening screen adds to the viewer; nil from the feed.
    var extras: MediaViewerExtras? = nil

    init(url: URL, allURLs: [URL]? = nil, extras: MediaViewerExtras? = nil) {
        self.url = url
        self.allURLs = (allURLs?.isEmpty == false ? allURLs! : [url])
        self.extras = extras
    }
}

/// Full-screen, swipeable viewer for a note's media. Opens on `selected` and pages
/// horizontally across `urls`, hosting one `FeedMediaViewer` per page (which already
/// yields horizontal drags to a parent `TabView` when not zoomed). On macOS — where
/// `PageTabViewStyle` is unavailable — it falls back to the single tapped item.
struct FeedMediaPager: View {
    let urls: [URL]
    let selected: URL
    var extras: MediaViewerExtras? = nil
    var onDismiss: (() -> Void)? = nil
    /// The page now showing, so the zoom can close into that photo's spot.
    var onPage: ((URL) -> Void)? = nil

    @State private var selection: URL
    @Environment(\.mediaZoomPresented) private var zoomPresented
    /// The tapped note, read once: `MeshMediaTap` forgets it after a few
    /// seconds, and the preloads below run for as long as the pager is open.
    private let meshNote = MeshMediaTap.note

    init(urls: [URL], selected: URL, extras: MediaViewerExtras? = nil,
         onDismiss: (() -> Void)? = nil, onPage: ((URL) -> Void)? = nil) {
        self.urls = urls.isEmpty ? [selected] : urls
        self.selected = selected
        self.extras = extras
        self.onDismiss = onDismiss
        self.onPage = onPage
        _selection = State(initialValue: selected)
    }

    var body: some View {
        #if os(iOS)
        if urls.count <= 1 {
            FeedMediaViewer(url: selected, extras: extras, onDismiss: onDismiss)
        } else {
            ZStack {
                // Each page draws its own black, which fades as it is pulled
                // away; a fixed black here would hide the post behind it.
                if !zoomPresented { Color.black.ignoresSafeArea() }
                TabView(selection: $selection) {
                    ForEach(urls, id: \.absoluteString) { url in
                        FeedMediaViewer(url: url, enableDragDismiss: true, isOnScreen: url == selection,
                                        extras: extras, onDismiss: onDismiss)
                            .tag(url)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                // A PageTabViewStyle TabView needs a definite size or it collapses
                // (renders as a small square and stops paging). Fill the screen like
                // MediaGalleryViewer's pager does.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .onChange(of: selection) { _, page in
                    onPage?(page)
                    preloadNeighbors(of: page)
                }
                .onAppear { preloadNeighbors(of: selection) }
            }
        }
        #else
        FeedMediaViewer(url: selected, extras: extras, onDismiss: onDismiss)
        #endif
    }

    /// Decodes the photos either side of `page`, so the next swipe in either
    /// direction lands on the photo rather than on a spinner.
    private func preloadNeighbors(of page: URL) {
        for url in PagerNeighbors.neighbors(of: page, in: urls) {
            ViewerPhotoPreloader.preload(url, note: meshNote)
        }
    }
}
