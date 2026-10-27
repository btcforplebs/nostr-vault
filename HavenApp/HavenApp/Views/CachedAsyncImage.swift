import SwiftUI

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var cachedImage: PlatformImage? = nil
    @State private var isLoading = false
    @State private var id = UUID() // Force refresh if URL changes

    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let platformImage = cachedImage {
                content(Image(platformImage: platformImage))
            } else {
                placeholder()
                    .onAppear {
                        load()
                    }
            }
        }
        .id(url) // Reset state when URL changes
    }

    private func load() {
        if isLoading { return }

        // 1. Check in-memory image cache (instant, no I/O)
        if let cached = MediaCacheService.shared.cachedImage(for: url) {
            self.cachedImage = cached
            return
        }

        // 2. Check disk cache + download on background queue (off main thread)
        isLoading = true

        let operation = BlockOperation { [url] in
            // Try disk cache first (now off main thread)
            if let data = MediaCacheService.shared.loadFromCache(url: url),
               let image = PlatformImage(data: data) {
                MediaCacheService.shared.cacheImage(image, for: url)
                DispatchQueue.main.async {
                    self.cachedImage = image
                    self.isLoading = false
                }
                return
            }

            // A `.fips` link is reachable only over the mesh.
            if MediaCacheService.isMeshOnly(url) {
                DispatchQueue.main.async { self.isLoading = false }
                return
            }

            // Download if not cached
            let task = MediaSessionService.shared.session.dataTask(with: url) { data, response, error in
                defer {
                    DispatchQueue.main.async { self.isLoading = false }
                }

                guard let data = data, error == nil,
                      let image = PlatformImage(data: data) else {
                    return
                }

                // Save to caches
                MediaCacheService.shared.saveToCache(url: url, data: data)
                MediaCacheService.shared.cacheImage(image, for: url)

                // Update UI
                DispatchQueue.main.async {
                    self.cachedImage = image
                }
            }
            task.resume()
        }

        // Use the shared queue to avoid thread explosions
        MediaCacheService.shared.downloadQueue.addOperation(operation)
    }
}
