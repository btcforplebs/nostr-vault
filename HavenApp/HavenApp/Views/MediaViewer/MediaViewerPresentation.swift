import SwiftUI

/// Namespace the tapped thumbnail and the full-screen viewer share, so the
/// viewer grows out of the photo's spot on screen and shrinks back into it.
private struct MediaZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// True inside a viewer presented with the zoom transition: the system then
/// owns swipe-down-to-dismiss, so the viewer's own drag must not fight it.
private struct MediaZoomPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mediaZoomNamespace: Namespace.ID? {
        get { self[MediaZoomNamespaceKey.self] }
        set { self[MediaZoomNamespaceKey.self] = newValue }
    }
    var mediaZoomPresented: Bool {
        get { self[MediaZoomPresentedKey.self] }
        set { self[MediaZoomPresentedKey.self] = newValue }
    }
    /// The photo the open viewer is showing. An inline carousel holding it
    /// turns to it, so the zoom closes into a photo that is on screen.
    var mediaViewerPage: URL? {
        get { self[MediaViewerPageKey.self] }
        set { self[MediaViewerPageKey.self] = newValue }
    }
}

private struct MediaViewerPageKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension View {
    /// Marks a tappable thumbnail as the place the viewer zooms out of.
    @ViewBuilder
    func mediaZoomSource(_ url: URL, namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *), let namespace {
            self.matchedTransitionSource(id: url.absoluteString, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Presents the media viewer for `item`. On iOS 18+ it zooms out of the
    /// tapped photo and swipes back down into it; earlier iOS and macOS keep
    /// the sheet.
    func mediaViewer(item: Binding<IdentifiableURL?>, namespace: Namespace.ID) -> some View {
        modifier(MediaViewerPresentation(item: item, namespace: namespace))
    }
}

private struct MediaViewerPresentation: ViewModifier {
    @Binding var item: IdentifiableURL?
    let namespace: Namespace.ID
    /// The page swiped to in the viewer; nil until the first swipe.
    @State private var page: URL?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            content
                .environment(\.mediaZoomNamespace, namespace)
                .environment(\.mediaViewerPage, item == nil ? nil : page)
                .fullScreenCover(item: $item, onDismiss: { page = nil }) { media in
                    FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { item = nil }, onPage: { page = $0 })
                        .environment(\.mediaZoomPresented, true)
                        .presentationBackground(.clear)
                        // Close into the photo on screen, not the one tapped.
                        .navigationTransition(.zoom(sourceID: (page ?? media.url).absoluteString, in: namespace))
                }
        } else {
            sheetFallback(content)
        }
        #else
        sheetFallback(content)
        #endif
    }

    private func sheetFallback(_ content: Content) -> some View {
        content.sheet(item: $item) { media in
            FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { item = nil })
        }
    }
}
