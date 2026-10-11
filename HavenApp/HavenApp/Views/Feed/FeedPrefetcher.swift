import SwiftUI

// MARK: - FeedPrefetcher

/// Starts the network work for feed rows before they are on screen. Every row
/// otherwise begins fetching in its own `onAppear`, so each one visibly
/// assembled itself as it scrolled in.
@MainActor
enum FeedPrefetcher {
    /// Rows to warm below the one that just appeared.
    static let lookahead = 8

    /// Matches `FeedPhotoView`'s full-size decode, so a warmed photo is the
    /// same cache entry the row will ask for.
    private static let photoMaxDimension: CGFloat = 800

    private static var warmedNoteIds = Set<String>()

    static func warm<S: Sequence>(_ notes: S, feedService: FeedService, nostrService: NostrService) where S.Element == FeedNote {
        guard !ConfigService.shared.config.disableMediaCache else { return }
        if warmedNoteIds.count > 5000 { warmedNoteIds.removeAll() }

        var missingProfiles: [String] = []
        for note in notes where warmedNoteIds.insert(note.id).inserted {
            if let pictureURL = nostrService.profiles[note.pubkey]?.pictureURL {
                AvatarImageCache.shared.load(url: pictureURL) { _ in }
            } else if nostrService.profiles[note.pubkey] == nil {
                missingProfiles.append(note.pubkey)
            }

            if note.isReply, let parentId = note.parentEventId {
                feedService.fetchMissingNote(id: parentId)
            }
            if note.kind == 6, note.content.isEmpty, let refId = note.repostedEventId {
                feedService.fetchMissingNote(id: refId)
            }
            for quoteId in note.quotedEventIds {
                feedService.fetchMissingNote(id: quoteId)
            }

            for url in note.mediaURLs {
                warmMedia(url)
            }
        }
        if !missingProfiles.isEmpty {
            nostrService.fetchMissingProfiles(for: missingProfiles)
        }
    }

    /// Photos are downloaded and decoded into the memory cache; GIFs only to
    /// disk. Videos and still-unclassified URLs are left alone: prefetching
    /// them costs whole files or HEAD requests for rows the user may never see.
    private static func warmMedia(_ url: URL) {
        switch MediaKindResolver.cachedKind(for: url) {
        case .image:
            guard MediaCacheService.shared.cachedImage(for: url) == nil else { return }
            Task(priority: .utility) {
                guard let data = await MediaCacheService.shared.fetchData(url: url, priority: .low),
                      MediaCacheService.shared.cachedImage(for: url) == nil,
                      let image = await ImageDownsampler.downsample(data: data, maxDimension: photoMaxDimension)
                else { return }
                MediaCacheService.shared.cacheImage(image, for: url)
            }
        case .gif:
            Task(priority: .utility) {
                _ = await MediaCacheService.shared.fetchData(url: url, priority: .low)
            }
        default:
            return
        }
    }
}
