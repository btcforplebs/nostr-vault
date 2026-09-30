import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's motion vocabulary.
///
/// Before this existed, the codebase carried **40+ distinct hand-written
/// curves** across ~400 animation call sites — `.easeInOut(duration: 0.15)`
/// next to `.easeInOut(duration: 0.2)` next to `.easeInOut(duration: 0.25)`,
/// eight different `.spring(response:dampingFraction:)` pairs, and a bare
/// `.spring()` in a few places. Every surface eased at its own speed, which is
/// why the app read as several apps stitched together rather than one.
///
/// The tokens below are named for **what the motion means**, not for the curve.
/// Pick by role and the timing follows:
///
/// | Token          | Use it for                                              |
/// |----------------|---------------------------------------------------------|
/// | `control`      | hover, press, selected state on a button or chip         |
/// | `toggle`       | switching a discrete mode: tab, view mode, filter        |
/// | `fade`         | content cross-fading in place                            |
/// | `media`        | an image or thumbnail arriving from cache or network     |
/// | `pick`         | choosing an item in a grid or viewer                     |
/// | `pop`          | tap feedback on like / repost / zap                      |
/// | `panel`        | expanding or collapsing a region                         |
/// | `chrome`       | scroll-driven toolbars and bars showing/hiding           |
/// | `bannerIn/Out` | a notification banner arriving and leaving               |
/// | `ambientPulse` | a decorative loop that runs while a state holds          |
/// | `shimmer`      | a skeleton placeholder breathing while content loads     |
/// | `scrollJump`   | a programmatic `scrollTo`                                |
/// | `snapBack`     | a drag returning to rest                                 |
/// | `dismiss`      | a gesture-driven dismissal                               |
///
/// ## Reduce Motion
///
/// The app previously had **no** Reduce Motion support at all: not one call
/// site consulted the setting. Every token here does. Under Reduce Motion:
///
/// - springs collapse to a plain fade of similar length, so nothing overshoots,
///   bounces, or springs back past its resting position;
/// - ambient loops (`ambientPulse`, `shimmer`) return `nil`, so a pulsing dot
///   simply stops instead of animating forever in the corner of someone's eye;
/// - `pillTransition` drops both the slide and the scale, cross-fading in place.
///
/// The setting is read at the moment an animation is created rather than
/// observed, so toggling it mid-session takes effect on the next animation
/// rather than retroactively. That is deliberate: it keeps these tokens usable
/// from non-`View` code (`VaultDataProcessing`, `PendingPostManager`) where
/// there is no `@Environment` to read.
enum Motion {

    // MARK: - Reduce Motion

    /// Whether the system is currently asking for reduced motion.
    static var isReduced: Bool {
        #if os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// A spring, or — when motion is reduced — a fade that lasts about as long.
    ///
    /// `response` is roughly the spring's period, so it doubles as a sensible
    /// duration for the fade that replaces it.
    ///
    /// `custom` is the escape hatch for a surface with a genuinely different
    /// tempo — the setup wizard's deliberately slower entrances. Reach for a
    /// named token first; a `custom` call in ordinary UI code is a sign the
    /// vocabulary is missing a word.
    static func custom(response: Double, dampingFraction: Double) -> Animation {
        spring(response, dampingFraction)
    }

    private static func spring(_ response: Double, _ damping: Double) -> Animation {
        isReduced
            ? .easeInOut(duration: response)
            : .spring(response: response, dampingFraction: damping)
    }

    // MARK: - Discrete state

    /// Hover, press, and selected state on a control.
    ///
    /// Fast enough to feel attached to the pointer or finger. Anything slower
    /// than ~0.15s reads as lag rather than as a transition.
    static var control: Animation { .easeInOut(duration: 0.14) }

    /// Switching a discrete mode — a tab, a view mode, a filter.
    ///
    /// Consolidates the old 0.15 / 0.2 / 0.25 spread. One speed, so switching
    /// tabs in the menu bar feels the same as switching view modes in the vault.
    static var toggle: Animation { .easeInOut(duration: 0.18) }

    // MARK: - Content

    /// Content cross-fading in place.
    ///
    /// Consolidates the old 0.2 / 0.25 / 0.3 easeInOut spread.
    static var fade: Animation { .easeInOut(duration: 0.22) }

    /// An image or thumbnail arriving.
    ///
    /// Deliberately `easeOut`, not the `easeIn` this used to be. An `easeIn`
    /// fade starts slow, so a picture that has already finished decoding still
    /// *looks* late — the exact opposite of what a media-heavy feed wants.
    /// `easeOut` puts most of the opacity change up front: the image is legible
    /// almost immediately and only the last few percent are animated.
    static var media: Animation { .easeOut(duration: 0.18) }

    /// Choosing an item in a grid or a media viewer.
    static var pick: Animation { spring(0.26, 0.8) }

    // MARK: - Feedback

    /// Tap feedback on like / repost / zap.
    ///
    /// The one place a little bounce is earned — it is the app's confirmation
    /// that a signed event went out. Damping stays low enough to read as a pop.
    static var pop: Animation { spring(0.28, 0.62) }

    /// The scale a `pop`-driven icon pulses to before returning to rest.
    static var pulseScale: CGFloat { 1.12 }

    /// Pops an icon to `pulseScale` and back via `pop`, for a caller that owns
    /// the *tap*, not the resulting state — a like that arrives from backfill
    /// or another client must not replay this.
    ///
    /// The hold before reset matches `pop`'s spring response, so the reset
    /// doesn't cut the outward spring off before it arrives at `pulseScale`.
    /// `nil` under Reduce Motion, same as the rest of this vocabulary — the
    /// icon's fill and color already carry the meaning.
    /// The confirmation burst for a zap landing — a small shockwave and
    /// spark scatter anchored to the bolt button, distinct from `pop`
    /// (the icon's own tap feedback). This is the payment's arrival.
    static var zapBurst: Animation { spring(0.46, 0.72) }

    /// A zap's visible trip across a note row, from the zapped author's
    /// avatar to the bolt button that sent it — an ease-out toss, not a
    /// spring, because a thrown object shouldn't bounce past where it's
    /// going. Callers (`ZapFlightView`) skip the flight outright under
    /// Reduce Motion rather than play a shortened version of it, same as
    /// `zapBurst`; this still degrades to a plain fade if ever driven
    /// directly, for defense in depth.
    static var zapFlight: Animation {
        isReduced ? .easeOut(duration: 0.2) : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.38)
    }

    static func firePulse(_ flag: Binding<Bool>) {
        guard !isReduced else { return }
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            flag.wrappedValue = false
        }
    }

    // MARK: - Structure

    /// Expanding or collapsing a region: a thread, a details panel, a sheet's
    /// internal steps.
    ///
    /// Consolidates the old 0.35 / 0.4 / 0.45 / 0.5 response spread, all of
    /// which were doing the same job at four different speeds.
    static var panel: Animation { spring(0.42, 0.82) }

    /// Scroll-driven chrome: toolbars and bars that hide as the feed scrolls.
    ///
    /// Damping is high (0.86, up from the old 0.75) on purpose. A bar that
    /// tracks your thumb and then overshoots its resting position reads as
    /// sloppy, because your thumb has already stopped moving and the bar has
    /// not. High damping makes it settle exactly where the gesture left it.
    static var chrome: Animation { spring(0.38, 0.86) }

    /// A programmatic jump: `scrollTo` a note, or back to the top of a feed.
    ///
    /// Damping is 0.9 — effectively critically damped — because a spring that
    /// overshoots at the *end* of a scroll looks like the list bounced off a
    /// wall it did not hit. Over the long distances these jumps cover, that
    /// overshoot is the only part of the motion the eye actually lands on.
    static var scrollJump: Animation { spring(0.45, 0.9) }

    /// A dragged element returning to rest after a gesture that did not commit.
    static var snapBack: Animation { spring(0.32, 0.72) }

    /// A gesture-driven dismissal — flinging a media viewer away.
    ///
    /// `easeOut` here, unlike `bannerOut`: the finger has already supplied the
    /// acceleration, so the animation's job is to carry that momentum out
    /// rather than to start one of its own.
    static var dismiss: Animation { .easeOut(duration: 0.2) }

    // MARK: - Overlays

    /// A notification banner arriving.
    ///
    /// Damping raised from the old 0.75 to 0.88: a banner that bounces on
    /// arrival draws a second beat of attention after it has already landed,
    /// which is precisely the wrong thing for something that interrupts.
    static var bannerIn: Animation { spring(0.34, 0.88) }

    /// A notification banner leaving.
    ///
    /// `easeIn`, and shorter than the old `easeOut(duration: 0.4)`. An element
    /// on its way out should accelerate away: `easeOut` lingers at the start,
    /// which made every dismissal feel like the banner was reluctant to go.
    static var bannerOut: Animation { .easeIn(duration: 0.24) }

    /// The transition every notification pill in the app shares: drops in from
    /// the top, shrinks away on dismissal.
    ///
    /// This exact `asymmetric` pair was pasted into eight places across four
    /// files. It is one token now, which also means the Reduce Motion variant
    /// only had to be written once — a cross-fade in place, with neither the
    /// slide nor the scale.
    static var pillTransition: AnyTransition {
        isReduced
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.8))
              )
    }

    // MARK: - Ambient loops

    /// A decorative loop that runs for as long as a state holds — a pulsing
    /// "relay is live" dot, a breathing zap bolt.
    ///
    /// `nil` under Reduce Motion, which stops the loop outright rather than
    /// merely slowing it. A `repeatForever` animation is the single most
    /// hostile thing on screen for someone who has asked for less movement,
    /// because unlike a transition it never ends.
    static var ambientPulse: Animation? {
        isReduced ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }

    /// A skeleton placeholder breathing while real content loads. `nil` under
    /// Reduce Motion, for the same reason as `ambientPulse`.
    static var shimmer: Animation? {
        isReduced ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    // MARK: - Staggering

    /// A token delayed by its position in a group, for revealing a row of
    /// controls one after another.
    ///
    /// The stagger is dropped entirely under Reduce Motion — a cascade is
    /// motion whether or not each individual step is a fade — and it is capped
    /// so a long list never turns into a slow wipe.
    static func staggered(_ animation: Animation, index: Int, step: Double = 0.05, cap: Int = 6) -> Animation {
        guard !isReduced else { return animation }
        return animation.delay(Double(min(index, cap)) * step)
    }
}
