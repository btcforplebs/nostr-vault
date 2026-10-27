import SwiftUI
import ImageIO
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A GIF (or animated WebP) tile that plays, for places that show many small
/// tiles at once: the composer's media row, the Blossom picker and the Vault
/// Media grid.
///
/// `AnimatedImage` decodes every frame up front, which is fine for one GIF on
/// screen but not for a grid of them. This view streams frames through
/// ImageIO's `CGAnimateImageDataWithBlock` instead, so a tile holds one
/// decoded frame at a time, and it only plays while the tile is on screen. Off
/// screen it stops and keeps the frame it was on.
/// With Reduce Motion on it shows the first frame.
struct AnimatedThumbnail: View {
    enum Source: Equatable {
        case url(URL)
        case data(Data)
    }

    let source: Source
    var contentMode: ContentMode = .fill

    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, contentMode: ContentMode = .fill) {
        self.source = .url(url)
        self.contentMode = contentMode
    }

    init(data: Data, contentMode: ContentMode = .fill) {
        self.source = .data(data)
        self.contentMode = contentMode
    }

    var body: some View {
        AnimatedFrameView(
            source: source,
            contentMode: contentMode,
            isPlaying: isVisible && !reduceMotion
        )
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Longest side, in pixels, of the still frame shown before playback starts.
private let posterMaxPixelSize = 480

#if os(macOS)
private struct AnimatedFrameView: NSViewRepresentable {
    let source: AnimatedThumbnail.Source
    let contentMode: SwiftUI.ContentMode
    let isPlaying: Bool

    func makeNSView(context: Context) -> AnimatedFrameLayerView { AnimatedFrameLayerView() }

    func updateNSView(_ view: AnimatedFrameLayerView, context: Context) {
        view.update(source: source, contentMode: contentMode, isPlaying: isPlaying)
    }
}

final class AnimatedFrameLayerView: NSView {
    let player = AnimatedFramePlayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: the view owns this layer and never draws into it.
        layer = player.layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(source: AnimatedThumbnail.Source, contentMode: SwiftUI.ContentMode, isPlaying: Bool) {
        player.update(source: source, contentMode: contentMode, isPlaying: isPlaying)
    }
}
#else
private struct AnimatedFrameView: UIViewRepresentable {
    let source: AnimatedThumbnail.Source
    let contentMode: SwiftUI.ContentMode
    let isPlaying: Bool

    func makeUIView(context: Context) -> AnimatedFrameLayerView { AnimatedFrameLayerView() }

    func updateUIView(_ view: AnimatedFrameLayerView, context: Context) {
        view.update(source: source, contentMode: contentMode, isPlaying: isPlaying)
    }
}

final class AnimatedFrameLayerView: UIView {
    let player = AnimatedFramePlayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.addSublayer(player.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.layer.frame = bounds
        CATransaction.commit()
    }

    func update(source: AnimatedThumbnail.Source, contentMode: SwiftUI.ContentMode, isPlaying: Bool) {
        player.update(source: source, contentMode: contentMode, isPlaying: isPlaying)
    }
}
#endif

/// Loads the bytes, shows a poster frame, and runs or stops ImageIO's frame
/// timer. Each start bumps `generation`; a frame callback from an older run
/// sets `stop` and is dropped, which is how playback is halted.
@MainActor
final class AnimatedFramePlayer {
    let layer = CALayer()

    private var source: AnimatedThumbnail.Source?
    private var data: Data?
    private var loadTask: Task<Void, Never>?
    private var isPlaying = false
    private var isRunning = false
    private var generation = 0

    init() {
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspectFill
    }

    func update(source: AnimatedThumbnail.Source, contentMode: SwiftUI.ContentMode, isPlaying: Bool) {
        layer.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        if source != self.source {
            self.source = source
            stop()
            data = nil
            layer.contents = nil
            load(source)
        }
        self.isPlaying = isPlaying
        if isPlaying { start() } else { stop() }
    }

    private func load(_ source: AnimatedThumbnail.Source) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let bytes: Data?
            switch source {
            case .data(let data):
                bytes = data
            case .url(let url):
                bytes = await Task.detached(priority: .utility) {
                    if let cached = MediaCacheService.shared.loadFromCache(url: url) { return cached }
                    return await MediaCacheService.shared.fetchData(url: url)
                }.value
            }
            guard let bytes, !Task.isCancelled else { return }
            let poster = await Task.detached(priority: .utility) { Self.posterFrame(bytes) }.value
            guard let self, !Task.isCancelled, self.source == source else { return }
            self.data = bytes
            if !self.isRunning { self.show(poster) }
            if self.isPlaying { self.start() }
        }
    }

    private func start() {
        guard !isRunning, let data else { return }
        isRunning = true
        generation += 1
        let run = generation
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == run else {
                    stop.pointee = true
                    return
                }
                self.show(image)
            }
        }
        if status != noErr { isRunning = false }
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
    }

    private func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    /// First frame, bounded so a large GIF's still doesn't cost a full decode.
    nonisolated private static func posterFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: posterMaxPixelSize
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
