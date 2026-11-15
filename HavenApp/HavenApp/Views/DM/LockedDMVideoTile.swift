import SwiftUI

/// A locked DM video (NIP-17 kind 15, DMFile) in a bubble (DM videos, 2026-11-15): downloaded with its size and
/// progress showing, checked and decrypted on this device, then played inline from the plain copy, muted and looping
/// like a feed clip. A tap opens it full screen with sound. A file that fails its hash or key says why, never the link.
struct LockedDMVideoTile: View {
    let sealed: DMFile.Sealed
    let size: CGFloat
    var mediaZoom: Namespace.ID? = nil
    /// Opens the decrypted copy in the full-screen player.
    var onOpen: ((URL) -> Void)? = nil

    private enum Phase: Equatable { case loading(got: Int, total: Int?), ready(URL), failed(String) }
    @State private var phase: Phase

    init(sealed: DMFile.Sealed, size: CGFloat, mediaZoom: Namespace.ID? = nil, onOpen: ((URL) -> Void)? = nil) {
        self.sealed = sealed
        self.size = size
        self.mediaZoom = mediaZoom
        self.onOpen = onOpen
        _phase = State(initialValue: DMFileTransfer.cached(sealed).map(Phase.ready) ?? .loading(got: 0, total: nil))
    }

    private var isLoading: Bool { if case .loading = phase { return true } else { return false } }

    var body: some View {
        Group {
            switch phase {
            case .ready(let url):
                InlineFeedVideoPlayer(url: url, onTap: { onOpen?(url) })
                    .frame(width: size, height: size)
                    .clipped()
                    .mediaZoomSource(url, namespace: mediaZoom)
                    .accessibilityLabel("Video")
                    .accessibilityHint("Tap to play full screen")
            case .loading(let got, let total):
                VStack(spacing: 8) {
                    Image(systemName: "video.fill").font(.appSystem(size: 22)).foregroundColor(.secondary)
                    if let total, total > 0 {
                        ProgressView(value: Double(min(got, total)), total: Double(total))
                            .frame(width: size * 0.6)
                        Text("\(DMFileTransfer.megabytes(got)) of \(DMFileTransfer.megabytes(total))")
                            .font(.appSystem(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        if got > 0 {
                            Text(DMFileTransfer.megabytes(got))
                                .font(.appSystem(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(width: size, height: size)
                .background(Color.gray.opacity(0.1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(loadingLabel(got: got, total: total))
            case .failed(let why):
                Button { phase = .loading(got: 0, total: nil); Task { await load() } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").font(.appSystem(size: 22))
                        Text(why).font(.appSystem(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundColor(.secondary)
                    .padding(10)
                    .frame(width: size, height: size * 0.6)
                    .background(Color.gray.opacity(0.1))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to try again")
            }
        }
        .task(id: sealed) { if isLoading { await load() } }
    }

    private func loadingLabel(got: Int, total: Int?) -> String {
        guard let total, total > 0 else { return "Video loading" }
        return "Video loading, \(DMFileTransfer.megabytes(got)) of \(DMFileTransfer.megabytes(total))"
    }

    private func load() async {
        do {
            let url = try await DMFileTransfer.open(sealed) { got, total in phase = .loading(got: got, total: total) }
            phase = .ready(url)
        } catch is CancellationError {
            // Scrolled off mid-download: stay loading, so it starts again when the tile comes back.
        } catch let error as URLError where error.code == .cancelled {
        } catch let refusal as DMFile.Refusal {
            phase = .failed(refusal == .x || refusal == .ox ? "This video was changed on the server." : "This video couldn't be unlocked.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
