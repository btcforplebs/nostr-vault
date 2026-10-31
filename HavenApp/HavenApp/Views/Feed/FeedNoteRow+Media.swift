import SwiftUI

extension FeedNoteRow {
    // MARK: - Media Grid Helper

    /// Renders media URLs using FeedMediaView in a swipeable carousel.
    @ViewBuilder
    func feedMediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            // Single media — full width, proper aspect ratio
            FeedMediaView(
                url: urls[0],
                onTap: { onMedia?(urls[0], urls) },
                maxHeight: 400,
                isThumbnail: false
            )
            .meshMediaNote(author: bodySource.pubkey, tags: bodySource.tags)
            .frame(maxWidth: .infinity)
        } else {
            // Multiple media — swipeable carousel. No fade on the pages: a page
            // swiped to fading in from clear showed the grey placeholder first.
            MediaPagerView(items: urls) { url in
                FeedMediaView(
                    url: url,
                    onTap: { onMedia?(url, urls) },
                    maxHeight: 400,
                    isThumbnail: false,
                    fillsFrame: true
                )
                .meshMediaNote(author: bodySource.pubkey, tags: bodySource.tags)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            // Every page fills the whole carousel (fillsFrame) rather than
            // sitting letterboxed in it.
            .frame(height: 400)
        }
    }

    /// Arms the terminal failure state for the parent-note skeleton: if the
    /// parent still hasn't arrived 12s after a fetch was requested, the
    /// skeleton is replaced with "Could not load original note" and a Retry
    /// action, instead of breathing forever.
    ///
    /// Deliberately does not re-check `rowData.parentNote` before setting the
    /// flag: `rowData` is a `let`, so this escaping closure would only ever
    /// see the value captured 12 seconds ago, never an arrival in between.
    /// Safe because the view always checks `if let parent = rowData.parentNote`
    /// before `else if parentFetchFailed` — a parent that loaded in the
    /// meantime renders regardless of this flag. Do not reorder those branches
    /// without giving this timeout a live way to observe the current note.
    /// A parent or quoted note replacing its skeleton: the swap itself is
    /// instant (a removal transition would keep the skeleton in the stack
    /// while the note fades in, briefly doubling the height), and only the
    /// arriving note fades.
    static var arrivalTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.media), removal: .identity)
    }

    /// Same budget as the parent fetch; collapses a quote that never arrives
    /// to one line instead of shimmering forever.
    func scheduleQuoteFetchTimeout(_ id: String) {
        guard !quoteFetchStarted.contains(id) else { return }
        quoteFetchStarted.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            quoteFetchFailed.insert(id)
        }
    }

    func scheduleParentFetchTimeout(_ id: String) {
        guard parentFetchStartedAt == nil else { return }
        parentFetchStartedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            parentFetchFailed = true
        }
    }
}
