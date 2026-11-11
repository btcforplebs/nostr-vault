import SwiftUI
import AVFoundation

struct VideoThumbnailView: View {
    let url: URL
    let mimeType: String?
    @State private var thumbnail: PlatformImage?
    @State private var isLoading: Bool
    @State private var id = UUID()

    init(url: URL, mimeType: String? = nil) {
        self.url = url
        self.mimeType = mimeType
        // Seed from cache so we never show a loading flash on subsequent renders.
        let cached = MediaCacheService.shared.memoryThumbnail(for: url)
        _thumbnail = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = thumbnail {
                    // The whole frame on a dark tile, not cropped to fill it (VideoTileFit).
                    let drawn = VideoTileFit.drawnSize(image: image.size, in: geo.size)
                    Color.black
                    Image(platformImage: image)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)

                    Image(systemName: "play.circle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                } else if isLoading {
                    ZStack {
                        LinearGradient(
                            colors: [Color.platformSecondaryGroupedBackground, Color(red: 0.06, green: 0.06, blue: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.6))

                        Image(systemName: "play.circle.fill")
                            .font(.appSystem(size: 40))
                            .foregroundColor(.white.opacity(0.3))
                            .shadow(radius: 2)
                    }
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.16, blue: 0.22), Color(red: 0.08, green: 0.08, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        VStack(spacing: 6) {
                            Image(systemName: "video.fill")
                                .font(.appSystem(size: 22))
                                .foregroundColor(.havenPurple.opacity(0.7))

                            Text("Video")
                                .font(.appSystem(size: 10, weight: .bold, design: .default))
                                .foregroundColor(.secondary.opacity(0.8))
                                .tracking(0.5)
                        }
                        .padding(.bottom, 4)

                        Image(systemName: "play.circle.fill")
                            .font(.appSystem(size: 40))
                            .foregroundColor(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .id(id)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        if thumbnail != nil { return }
        isLoading = true

        Task {
            let image = await MediaCacheService.shared.generateThumbnail(for: url, mimeType: mimeType)
            await MainActor.run {
                self.thumbnail = image
                self.isLoading = false
            }
        }
    }
}
