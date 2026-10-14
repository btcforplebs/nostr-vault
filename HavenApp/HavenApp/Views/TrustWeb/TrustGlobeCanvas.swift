import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The globe itself: one Canvas, with a frame clock that runs only while
/// something on it moves. Real pictures are Canvas symbols, so a frame never
/// lays out a view.
struct TrustGlobeCanvas: View {
    let frame: TrustWebView.Frame?
    let center: String
    let me: String
    let author: String
    let myFollows: Set<String>
    let haze: [String]
    /// The part of the haze at least `TrustMap.closeVouches` of your follows follow.
    var closeHaze: Set<String> = []
    /// Follows drawn as faces when the core is the person everyone is
    /// measured against (your own globe on the WOT tab).
    let ringFaces: [String]
    /// Pictures on the outer shell for the picked layer (Close or Further
    /// out), on your own globe.
    var layerFaces: [String] = []
    /// Who the filter icons leave lit; nil when none is on.
    var filterLit: Set<String>? = nil
    /// False while a sheet covers the globe: the clock stops.
    let running: Bool
    /// Which part of the web is lit (the WOT tab's layer picker).
    var layer: TrustMap.Layer = .everyone
    let summary: String
    let avatar: (String, CGFloat) -> AnyView
    let name: (String) -> String
    let onTap: (String) -> Void
    /// The person the trust card is about: the globe turns to face them.
    var focus: String? = nil
    /// The people you follow who follow `focus`: its threads run through them.
    var focusBridges: [String] = []
    /// A tap that lands on no one, e.g. to close the trust card.
    var onEmptyTap: () -> Void = {}
    /// The WOT tab's globe, where the bar's Live arrivals switch draws notes
    /// arriving at the relay. A post's globe never does.
    var liveArcs = false

    /// The globe shows about this many times `TrustMap`'s face counts: more
    /// pictures overall, not quite double (Logen, 10/14).
    nonisolated static let faceScale = 1.8
    nonisolated static func faces(_ count: Int) -> Int { Int((Double(count) * faceScale).rounded()) }
    /// Bridges drawn as faces; the rest stay bright stars.
    static let maxFaces = faces(12)
    /// Spinning and turning to a person both take about this long; a new
    /// person's globe settles in after it.
    private static let turnDelay: Duration = .milliseconds(380)

    @StateObject private var scene = GlobeScene()
    @StateObject private var arrivals = GlobeArrivalStream()
    @AppStorage(LiveArcsSetting.key) private var liveArcsOn = false
    /// A landed note's preview was tapped: the note opens over the globe.
    @State private var openNote: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appIsActive = true
    @State private var lastDrag: CGSize = .zero
    @State private var pinchBase: CGFloat = 1
    /// Reset by SwiftUI when a gesture ends *or is cancelled*; `onEnded` is
    /// skipped on cancel, so this is what puts the camera back to rest.
    @GestureState private var dragActive = false
    @GestureState private var pinchActive = false

    private struct LoadKey: Hashable {
        let center: String
        let ring: Int
        let bridges: Int
        let chains: Int
        let haze: Int
        let close: Int
        let mine: Int
        /// Who is in the ring, not just how many: a follow and an unfollow
        /// together keep the count.
        let ringHash: Int
        /// Who is in the haze: past its cap, a newcomer swaps in for someone
        /// at the margin and the count stays put.
        let hazeHash: Int
        let faces: [String]
        let layerFaces: [String]
    }

    private var loadKey: LoadKey? {
        frame.map {
            LoadKey(center: $0.center, ring: $0.ring.count, bridges: $0.bridges.count,
                    chains: $0.chains?.count ?? -1, haze: haze.count, close: closeHaze.count, mine: myFollows.count,
                    ringHash: $0.ring.hashValue, hazeHash: haze.hashValue, faces: ringFaces,
                    layerFaces: layerFaces)
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Full rate only under a finger (a drag, its flick, a pinch).
            // Drift, settling and arcs at 30 fps: the idle globe was the heat.
            TimelineView(.animation(minimumInterval: scene.fullRate || pinchActive ? nil : 1 / GlobeScene.slowRate,
                                    paused: !scene.awake || !clockAllowed)) { timeline in
                Canvas { context, size in
                    scene.tick(now: timeline.date.timeIntervalSinceReferenceDate)
                    scene.draw(in: &context, size: size, accent: .orange, name: name)
                } symbols: {
                    ForEach(scene.faceKeys, id: \.self) { key in
                        avatar(key, GlobeScene.pictureSize).tag(key)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(drag.simultaneously(with: magnify))
            .simultaneousGesture(taps(in: geo.size))
            .accessibilityElement()
            .accessibilityLabel(Text("Web of Trust globe"))
            .accessibilityValue(Text(summary))
            .accessibilityHint(Text("Swipe up or down to zoom. Actions go to a person."))
            .accessibilityAdjustableAction { direction in
                let range = GlobeCamera.zoomRange
                let step = direction == .increment ? 0.3 : -0.3
                scene.camera.zoomTarget = min(range.upperBound, max(range.lowerBound, scene.camera.zoomTarget + step))
                scene.camera.touch(at: Date.timeIntervalSinceReferenceDate)
                scene.wake()
            }
            .accessibilityActions {
                ForEach(scene.faceKeys.filter { $0 != center }, id: \.self) { key in
                    Button("Go to \(name(key))") { onTap(key) }
                }
                Button("Reset view") { scene.reset() }
            }
            // Over the gestures, not under them: a tap on a preview opens its
            // note and never also lands on the face beneath it.
            .overlay { previews(in: geo.size) }
        }
        .onAppear {
            scene.reduceMotion = reduceMotion
            scene.focus(layer)
            scene.filter(filterLit)
        }
        .onChange(of: layer) { _, layer in scene.focus(layer) }
        .task(id: liveArcs && liveArcsOn) {
            // Listens while the switch is on and the globe is on screen; leaving
            // the tab cancels this, and coming back starts it again.
            guard liveArcs && liveArcsOn else { return }
            scene.setLiveArcs(true)
            let token = arrivals.start(me: me)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            // A quick off and on can start the next run before this one ends.
            if arrivals.stop(token) { scene.setLiveArcs(false) }
        }
        // While the clock is stopped nothing would move them on: they're
        // dropped rather than piling up behind a sheet or another app.
        .onReceive(arrivals.arrived) { if clockAllowed { scene.arrive($0) } }
        .sheet(item: Binding<IdentifiableString?>(
            get: { openNote.map { IdentifiableString(id: $0) } },
            set: { openNote = $0?.id }
        )) { note in
            NoteDetailViewWrapper(noteId: note.id, onDismiss: { openNote = nil })
        }
        .onChange(of: filterLit) { _, lit in scene.filter(lit) }
        .onChange(of: focus) { _, key in
            if let key { scene.turn(to: key) }
            scene.trace(to: key, through: focusBridges)
        }
        .onChange(of: focusBridges) { _, bridges in scene.trace(to: focus, through: bridges) }
        .onChange(of: reduceMotion) { _, reduced in
            scene.reduceMotion = reduced
            if reduced { scene.camera.spin = .zero }
            scene.wake()
        }
        .onChange(of: center) { _, key in scene.turn(to: key) }
        .onChange(of: dragActive) { _, active in
            guard !active else { return }
            scene.camera.dragging = false
            lastDrag = .zero
            scene.wake()
        }
        .onChange(of: pinchActive) { _, active in
            if !active { pinchBase = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.didBecomeActive)) { _ in appIsActive = true }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.willResignActive)) { _ in appIsActive = false }
        .task(id: loadKey) {
            guard let frame else { return }
            // Turn to the new person first, then let the globe re-settle around them.
            if scene.hasLoaded, frame.center != scene.center, !reduceMotion {
                try? await Task.sleep(for: Self.turnDelay)
                guard !Task.isCancelled else { return }
            }
            scene.load(frame, me: me, author: author, myFollows: myFollows, haze: haze, closeHaze: closeHaze,
                       ringFaces: ringFaces, layerFaces: layerFaces, layer: layer)
        }
    }

    /// False while a sheet or another app covers the globe: the clock stops.
    private var clockAllowed: Bool { running && appIsActive && openNote == nil }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { value in
                let now = Date.timeIntervalSinceReferenceDate
                scene.dismissPreviews()
                scene.camera.dragging = true
                scene.camera.drag(dx: value.translation.width - lastDrag.width,
                                  dy: value.translation.height - lastDrag.height, at: now)
                lastDrag = value.translation
                scene.wake()
            }
            .onEnded { value in
                scene.camera.dragging = false
                lastDrag = .zero
                scene.camera.flick(vx: value.velocity.width, vy: value.velocity.height,
                                   at: Date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                scene.wake()
            }
    }

    /// Landed notes beside their faces, above them unless that runs off the top.
    private func previews(in size: CGSize) -> some View {
        ZStack {
            ForEach(scene.previews) { preview in
                let width = min(240, size.width - 24)
                let x = min(max(preview.point.x, width / 2 + 12), size.width - width / 2 - 12)
                let y = preview.point.y > 190 ? preview.point.y - 48 : preview.point.y + 48
                GlobeNotePreview(avatar: avatar(preview.author, 24), name: name(preview.author),
                                 text: preview.text) { openNote = preview.id }
                    .frame(width: width)
                    .position(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinchActive) { _, active, _ in active = true }
            .onChanged { value in
                let range = GlobeCamera.zoomRange
                let zoom = scene.camera.zoomTarget * Double(value.magnification / pinchBase)
                scene.camera.zoomTarget = min(range.upperBound, max(range.lowerBound, zoom))
                scene.camera.touch(at: Date.timeIntervalSinceReferenceDate)
                pinchBase = value.magnification
                scene.wake()
            }
            .onEnded { _ in pinchBase = 1 }
    }

    /// A double-tap resets; a single tap waits until it can't be one, so a
    /// double-tap on a face doesn't also fly there.
    private func taps(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in scene.reset() }
            .exclusively(before: SpatialTapGesture().onEnded { tap in
                guard let key = scene.hit(tap.location, in: size) else { return onEmptyTap() }
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                onTap(key)
            })
    }
}
