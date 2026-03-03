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
        
        // 1. Check disk cache synchronously (it's fast enough for main thread usually, or we could dispatch)
        if let data = MediaCacheService.shared.loadFromCache(url: url),
           let image = PlatformImage(data: data) {
            self.cachedImage = image
            return
        }
        
        // 2. Download if not cached
        isLoading = true
        
        let operation = BlockOperation {
            // Using MediaSessionService which handles localhost certificates
            let task = MediaSessionService.shared.session.dataTask(with: url) { data, response, error in
                defer { 
                    DispatchQueue.main.async { self.isLoading = false }
                }
                
                guard let data = data, error == nil,
                      let image = PlatformImage(data: data) else {
                    return
                }
                
                // Save to cache
                MediaCacheService.shared.saveToCache(url: url, data: data)
                
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
