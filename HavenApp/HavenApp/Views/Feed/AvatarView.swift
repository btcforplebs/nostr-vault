import SwiftUI
import Combine

// MARK: - AvatarView

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    var size: CGFloat = 40
    /// A neutral silhouette instead of the coloured initial, for lists where
    /// a pubkey's first hex digit would read as noise.
    var neutralPlaceholder = false
    /// False for a stranger the WoT gate holds back: their picture is never
    /// fetched (its host would learn you looked), and their constellation is
    /// drawn instead (Logen 2026-11-21).
    var load = true
    @State private var image: PlatformImage?
    /// The picture that failed, so a newer picture still gets its chance.
    @State private var failedURL: URL?
    @State private var profileArrived = false

    /// The picture to fetch, if any.
    private var pictureURL: URL? { load ? url : nil }

    /// No picture to show, and nothing still loading: the profile has no
    /// picture, its picture failed, or the gate holds it back. Before a
    /// profile arrives the plain disc stays (spec: NV_CONSTELLATION_AVATAR_SPEC).
    private var showsConstellation: Bool {
        guard image == nil else { return false }
        if !load { return true }
        if let pictureURL { return failedURL == pictureURL }
        return profileKnown
    }

    private var profileKnown: Bool {
        profileArrived || NostrService.shared.profiles[pubkey] != nil
    }

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

            if showsConstellation {
                ConstellationFace(pubkey: pubkey, size: size)
            } else if let image = image {
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
        .background {
            // Only a face still waiting for its profile listens for it.
            if load && pictureURL == nil && !profileKnown {
                ProfileArrivalWatch(pubkey: pubkey) { profileArrived = true }
            }
        }
        .modifier(LiveAvatarRing(pubkey: pubkey, size: size))
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: load) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: pubkey) { _, _ in
            image = nil
            profileArrived = false
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
        guard let url = pictureURL else { return }

        // Fast synchronous path for the memory cache so already-loaded avatars
        // render without a flash.
        if let cached = AvatarImageCache.shared.image(for: url) {
            if image == nil { image = cached }
            return
        }

        guard image == nil else { return }
        AvatarImageCache.shared.load(url: url) { img in
            if let img = img {
                image = img
            } else if url == pictureURL {
                failedURL = url
            }
        }
    }
}

/// Sets `profileArrived` once a profile for `pubkey` lands, so a face drawn
/// before its kind 0 turns into the constellation without its parent
/// re-rendering.
private struct ProfileArrivalWatch: View {
    let pubkey: String
    let arrived: () -> Void

    var body: some View {
        Color.clear
            .onReceive(NostrService.shared.$profiles.map { $0[pubkey] != nil }.removeDuplicates()) { known in
                if known { arrived() }
            }
    }
}
