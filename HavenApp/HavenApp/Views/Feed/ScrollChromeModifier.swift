import SwiftUI

@available(macOS 15.0, iOS 18.0, *)
private struct ScrollChromeModifier: ViewModifier {
    var isAtTopBinding: Binding<Bool>?

    /// Per-frame bookkeeping. A plain class held in `@State`, so writing it
    /// every frame does not invalidate this modifier (and re-emit the whole
    /// scroll content) the way a `@State` value write would.
    private final class Tracker {
        var phase: ScrollPhase = .idle
        var lastOffset: CGFloat?
        /// Direction of the finger's most recent movement, +1 = down the list.
        var lastDirection: CGFloat = 0
        /// Set when a fling has already chosen where the bars go; the rest
        /// of that deceleration no longer moves them.
        var committed = false
    }

    @State private var tracker = Tracker()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // Offset from the top of the content, clamped to the
                // scrollable range, so rubber-banding past either end
                // produces no movement.
                let top = geo.contentOffset.y + geo.contentInsets.top
                let maxOffset = max(0, geo.contentSize.height + geo.contentInsets.top
                                    + geo.contentInsets.bottom - geo.containerSize.height)
                return min(max(top, 0), maxOffset)
            } action: { _, offset in
                handle(offset: offset)
            }
            .onScrollPhaseChange { _, newPhase, context in
                handle(phase: newPhase, velocity: context.velocity?.dy)
            }
    }

    private var chrome: ChromeCollapse { .shared }

    private var isPinnedOpen: Bool {
        ConfigService.shared.config.disableTabBarAnimation
    }

    /// The bars can be at most this folded at a given offset, so the top of
    /// a list always shows them in full and a list shorter than `distance`
    /// can only fold them partway (and then settles them back open).
    private func ceiling(at offset: CGFloat) -> CGFloat {
        offset / ChromeCollapse.distance
    }

    private func handle(offset: CGFloat) {
        let last = tracker.lastOffset
        tracker.lastOffset = offset

        if let binding = isAtTopBinding {
            let atTop = offset <= 10
            if atTop != binding.wrappedValue { binding.wrappedValue = atTop }
        }

        if isPinnedOpen {
            if chrome.progress != 0 { chrome.track(0) }
            return
        }

        switch tracker.phase {
        case .interacting, .decelerating:
            // Only the finger and its fling move the bars. A programmatic
            // scroll (.animating) or a content change while idle — new notes
            // inserted above, a restored position, load-more — does not.
            guard let last, !tracker.committed else { break }
            let delta = offset - last
            if delta != 0 { tracker.lastDirection = delta > 0 ? 1 : -1 }
            chrome.track(min(chrome.progress + delta / ChromeCollapse.distance,
                             ceiling(at: offset)))
            return
        default:
            break
        }

        // Whatever moved the list, arriving at the top shows the bars.
        let cap = ceiling(at: offset)
        if chrome.progress > cap {
            if tracker.phase == .animating { chrome.track(cap) } else { chrome.settle(to: cap) }
        }
    }

    private func handle(phase newPhase: ScrollPhase, velocity: CGFloat?) {
        let oldPhase = tracker.phase
        tracker.phase = newPhase
        guard !isPinnedOpen else { return }
        let offset = tracker.lastOffset ?? 0
        let canFold = ceiling(at: offset) >= 1

        switch newPhase {
        case .interacting:
            tracker.committed = false
            tracker.lastDirection = 0
        case .decelerating:
            // Lifting the finger mid-fling: a fast fling picks its end now.
            // Direction comes from the finger's last movement; only the
            // velocity's magnitude is used.
            if oldPhase == .interacting, let velocity,
               abs(velocity) >= ChromeCollapse.flingVelocity, tracker.lastDirection != 0 {
                chrome.settle(to: tracker.lastDirection > 0 && canFold ? 1 : 0)
                tracker.committed = true
            }
        case .idle:
            tracker.committed = false
            // Never leave the bars half-folded.
            let p = chrome.progress
            guard p > 0, p < 1 else { return }
            chrome.settle(to: p >= 0.5 && canFold ? 1 : 0)
        default:
            break
        }
    }
}

extension View {
    @ViewBuilder
    func scrollDirectionTracking(feedService: FeedService, isAtTop: Binding<Bool>? = nil) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.modifier(ScrollChromeModifier(isAtTopBinding: isAtTop))
        } else {
            self
        }
    }
}
