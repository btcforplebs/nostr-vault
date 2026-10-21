import SwiftUI

struct RetryableAsyncImage: View {
    @EnvironmentObject var configService: ConfigService
    let url: URL
    let contentMode: ContentMode
    var targetSize: CGSize? = nil
    @State private var id = UUID()
    @State private var retryCount = 0
    @State private var cachedImage: PlatformImage?
    @State private var isLoading = false

    init(url: URL, contentMode: ContentMode, targetSize: CGSize? = nil) {
        self.url = url
        self.contentMode = contentMode
        self.targetSize = targetSize
        // Seed from in-memory cache for instant rendering
        _cachedImage = State(initialValue: MediaCacheService.shared.cachedImage(for: url))
        _isLoading = State(initialValue: false)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = cachedImage {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if isLoading {
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.1))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if MediaCacheService.isMeshOnly(url) {
                    // AsyncImage would resolve the `.fips` host itself.
                    Rectangle().fill(Color.gray.opacity(0.1))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Rectangle().fill(Color.gray.opacity(0.1))
                                ProgressView().controlSize(.small)
                            }
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: contentMode)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .onAppear {
                                    // checkCache() will handle caching logic
                                }
                        case .failure:
                             ZStack {
                                Rectangle().fill(Color.havenPurplePale.opacity(0.3))
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.fill.on.rectangle.fill")
                                        .font(.appSystem(size: 28))
                                        .foregroundColor(.havenPurple.opacity(0.8))

                                    VStack(spacing: 2) {
                                        Text("Media Missing")
                                            .font(.appSystem(size: 11, weight: .bold))
                                        Text("Error 404")
                                            .font(.appSystem(size: 9))
                                            .textCase(.uppercase)
                                    }
                                    .foregroundColor(.havenPurple)

                                    Button(action: {
                                        id = UUID()
                                        retryCount += 1
                                        checkCache()
                                    }) {
                                        Text("Try Again")
                                            .font(.appSystem(size: 10, weight: .bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.havenPurple)
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 4)
                                }
                                .padding(8)
                            }
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .id(id)
        .onAppear {
            checkCache()
        }
    }

    private func checkCache() {
        // If we already have it from init (in-memory cache), we're done
        if cachedImage != nil { return }

        // 2. Try to load it directly from disk cache (General cache or Blossom)
        if let data = MediaCacheService.shared.loadFromCache(url: url) {
            Task {
                if let image = await decode(data: data) {
                    await MainActor.run {
                        self.cachedImage = image
                        // Cache in memory for next time
                        MediaCacheService.shared.cacheImage(image, for: url)
                    }
                } else {
                    await handleMissedCache()
                }
            }
            return
        }

        Task {
            await handleMissedCache()
        }
    }

    private func handleMissedCache() async {
        // 2. If it's a grid item (targetSize set) or not found, try fetching
        // Note: For local Blossom, fetchData just pulls from local server but does not re-cache
        if targetSize != nil || self.cachedImage == nil {
            autoCache()
        }
    }

    private func autoCache() {
        isLoading = true
        Task {
            if let data = await MediaCacheService.shared.fetchData(url: url),
               let image = await decode(data: data) {
                await MainActor.run {
                    self.cachedImage = image
                    self.isLoading = false
                    // Cache in memory for next time
                    MediaCacheService.shared.cacheImage(image, for: url)
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    nonisolated private func decode(data: Data) async -> PlatformImage? {
        if let targetSize = targetSize,
           let downsampled = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height)) {
            return downsampled
        }
        return await Task.detached(priority: .utility) {
            PlatformImage(data: data)
        }.value
    }
}
