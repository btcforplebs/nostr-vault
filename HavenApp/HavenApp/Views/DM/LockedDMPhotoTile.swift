import SwiftUI

/// A locked DM photo (NIP-17 kind 15, DMFile) in a bubble: downloaded, checked and decrypted on this device, then
/// drawn from the plain copy. A file that fails its hash or key shows why instead of a picture, and never the link.
struct LockedDMPhotoTile: View {
    let sealed: DMFile.Sealed
    let size: CGFloat
    var mediaZoom: Namespace.ID? = nil
    /// Opens the decrypted copy in the viewer.
    var onOpen: ((URL) -> Void)? = nil

    private enum Phase: Equatable { case loading, ready(URL), failed(String) }
    @State private var phase: Phase

    init(sealed: DMFile.Sealed, size: CGFloat, mediaZoom: Namespace.ID? = nil, onOpen: ((URL) -> Void)? = nil) {
        self.sealed = sealed
        self.size = size
        self.mediaZoom = mediaZoom
        self.onOpen = onOpen
        _phase = State(initialValue: DMFileTransfer.cached(sealed).map(Phase.ready) ?? .loading)
    }

    var body: some View {
        Group {
            switch phase {
            case .ready(let url) where sealed.isImage:
                Button { onOpen?(url) } label: {
                    // Drawn from the plain copy on disk: the network image views read only remote and vault URLs.
                    Group {
                        if let image = Self.image(at: url) {
                            Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.1))
                        }
                    }
                    .frame(width: size, height: size)
                    .clipped()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .mediaZoomSource(url, namespace: mediaZoom)
                .accessibilityLabel("Photo")
            case .ready:
                status(icon: "doc.fill", text: "File (\(sealed.mime))")
            case .loading:
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.1))
                    ProgressView().controlSize(.small)
                }
                .frame(width: size, height: size)
                .accessibilityLabel("Photo loading")
            case .failed(let why):
                Button { phase = .loading; Task { await load() } } label: {
                    status(icon: "lock.trianglebadge.exclamationmark", text: why)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to try again")
            }
        }
        .task(id: sealed) { if phase == .loading { await load() } }
    }

    private func status(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.appSystem(size: 22))
            Text(text).font(.appSystem(size: 11)).multilineTextAlignment(.center)
        }
        .foregroundColor(.secondary)
        .padding(10)
        .frame(width: size, height: size * 0.6)
        .background(Color.gray.opacity(0.1))
    }

    /// The decrypted photo, kept in the shared image cache so the viewer opens it without reading the disk again.
    private static func image(at url: URL) -> PlatformImage? {
        if let hit = MediaCacheService.shared.cachedImage(for: url) { return hit }
        guard let image = PlatformImage(contentsOfFile: url.path) else { return nil }
        MediaCacheService.shared.cacheImage(image, for: url)
        return image
    }

    private func load() async {
        do {
            phase = .ready(try await DMFileTransfer.open(sealed))
        } catch let refusal as DMFile.Refusal {
            phase = .failed(refusal == .x || refusal == .ox ? "This photo was changed on the server." : "This photo couldn't be unlocked.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
