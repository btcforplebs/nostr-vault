import SwiftUI

// MARK: - AvatarView

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    var size: CGFloat = 40
    /// A neutral silhouette instead of the coloured initial, for lists where
    /// a pubkey's first hex digit would read as noise.
    var neutralPlaceholder = false
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if neutralPlaceholder {
                Circle()
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: size, height: size)
            }

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if neutralPlaceholder {
                Image(systemName: "person.fill")
                    .font(.appSystem(size: size * 0.45))
                    .foregroundColor(.secondary.opacity(0.6))
                    .offset(y: size * 0.04)
            } else {
                Text(String(pubkey.prefix(1)).uppercased())
                    .font(.appSystem(size: max(8, size * 0.325), weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Circle()
                .stroke(Color.platformSeparator, lineWidth: 0.5)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipped()
        .modifier(LiveAvatarRing(pubkey: pubkey, size: size))
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: pubkey) { _, _ in
            image = nil
            loadImage()
        }
    }

    private var avatarGradient: LinearGradient {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        let hue = Double(first % 360) / 360.0
        let saturation = 0.6 + Double((first / 10) % 30) / 100.0

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: 0.75),
                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage() {
        guard let url = url else { return }

        // Fast synchronous path for the memory cache so already-loaded avatars
        // render without a flash.
        if let cached = AvatarImageCache.shared.image(for: url) {
            if image == nil { image = cached }
            return
        }

        guard image == nil else { return }
        AvatarImageCache.shared.load(url: url) { img in
            if let img = img { image = img }
        }
    }
}
