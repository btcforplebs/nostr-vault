import SwiftUI

// MARK: - Zoom presentation

/// Follows the zoom transition's swipe-down on the presented viewer, so the
/// black and the buttons can fade with it. Once the finger lifts, `pull`
/// returns to zero only if the swipe put the viewer back; on a close it
/// holds, or the black would come back during the flight into the post.
final class ZoomSwipeWatch: NSObject, ObservableObject {
    @Published private(set) var pull: CGFloat = 0

    #if os(iOS)
    private weak var swipe: UIGestureRecognizer?

    /// UIKit's name for the zoom transition's swipe-down recognizer. If a
    /// later iOS renames it, the swipe still closes the viewer; only the
    /// fade is lost.
    private static let swipeName = "com.apple.UIKit.ZoomInteractiveDismissSwipeDown"

    // Each page of a pager attaches to the same recognizer, and pages come
    // and go while the cover stays up.
    deinit { swipe?.removeTarget(self, action: nil) }

    func attach(from view: UIView) {
        guard swipe == nil else { return }
        var ancestor: UIView? = view
        while let v = ancestor {
            if let g = v.gestureRecognizers?.first(where: { $0.name == Self.swipeName }) {
                g.addTarget(self, action: #selector(track(_:)))
                swipe = g
                return
            }
            ancestor = v.superview
        }
    }

    @objc private func track(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            if let pan = g as? UIPanGestureRecognizer {
                pull = pan.translation(in: nil).y
            }
        case .ended, .cancelled, .failed:
            settle(from: g.view)
        default:
            break
        }
    }

    private func settle(from view: UIView?) {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        guard var controller = responder as? UIViewController else { return restore() }
        while let parent = controller.parent { controller = parent }
        guard controller.isBeingDismissed, let coordinator = controller.transitionCoordinator else {
            return restore()
        }
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] in
                if $0.isCancelled { self?.restore() }
            }
        } else if coordinator.isCancelled {
            restore()
        }
    }

    private func restore() {
        guard pull != 0 else { return }
        withAnimation(Motion.snapBack) { pull = 0 }
    }
    #endif
}

#if os(iOS)
/// Finds the zoom's swipe-down once the viewer is on screen.
struct ZoomSwipeProbe: UIViewRepresentable {
    let watch: ZoomSwipeWatch

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.watch = watch
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        weak var watch: ZoomSwipeWatch?
        // The presentation may install the swipe after this view joins the
        // window, so look again on layout until it is found.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { watch?.attach(from: self) }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil { watch?.attach(from: self) }
        }
    }
}
#else
struct ZoomSwipeProbe: View {
    let watch: ZoomSwipeWatch
    var body: some View { EmptyView() }
}
#endif
