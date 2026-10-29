import SwiftUI

#if os(iOS)
import UIKit

extension View {
    /// Pulling down from the very top of the enclosing scroll view closes the
    /// page (see `PullDownToCloseRule`). Place it inside the scroll content;
    /// it finds its UIScrollView and listens to the scroll's own pan, so
    /// ordinary scrolling is untouched.
    func pullDownToClose(_ close: @escaping () -> Void) -> some View {
        background(PullDownToCloseProbe(close: close))
    }
}

private struct PullDownToCloseProbe: UIViewRepresentable {
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.close = close
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var current = superview
            while let v = current, !(v is UIScrollView) { current = v.superview }
            if let scroll = current as? UIScrollView { coordinator?.attach(to: scroll) }
        }
    }

    final class Coordinator: NSObject {
        var close: () -> Void = {}
        private weak var scrollView: UIScrollView?
        private var startedAtTop = false

        func attach(to scroll: UIScrollView) {
            guard scroll !== scrollView else { return }
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
            scrollView = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        }

        /// Points the content sits below its resting top; positive when pulled down.
        private func overscroll(_ scroll: UIScrollView) -> Double {
            -(scroll.contentOffset.y + scroll.adjustedContentInset.top)
        }

        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let scroll = scrollView else { return }
            switch recognizer.state {
            case .began:
                startedAtTop = PullDownToCloseRule.isAtTop(overscroll: overscroll(scroll))
            case .ended:
                if PullDownToCloseRule.shouldClose(startedAtTop: startedAtTop,
                                                   overscrollAtRelease: overscroll(scroll)) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    close()
                }
                startedAtTop = false
            case .cancelled, .failed:
                startedAtTop = false
            default:
                break
            }
        }
    }
}
#else
extension View {
    func pullDownToClose(_ close: @escaping () -> Void) -> some View { self }
}
#endif
