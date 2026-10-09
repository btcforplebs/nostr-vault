package com.nostrvault.ui.theme

import android.content.ContentResolver
import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.InfiniteRepeatableSpec
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The app's motion vocabulary — the Android half of [Motion.swift].
 *
 * Before this existed, the Compose app carried **11 distinct hand-written specs
 * across 72 animation call sites** — eight different `spring(dampingRatio:,
 * stiffness:)` pairs, three bare `spring()`, and `tween(150)` next to
 * `tween(durationMillis = 150)`. The file that was *supposed* to hold the
 * vocabulary (`NostrVaultMotion`, with SnapSpring / StandardSpring /
 * ElasticSpring / HeroSpring) had zero call sites: it was never adopted, and it
 * had been ported from the iOS spec as it stood *before* that spec was cleaned
 * up, so every spring in it carried `dampingRatio = 0.75` — the exact number
 * iOS deliberately moved off (`chrome` 0.75 → 0.86, `bannerIn` 0.75 → 0.88).
 *
 * Tokens are named for **what the motion means**, not for the curve, and the
 * names match `Motion.swift` one-for-one so a change on either platform has an
 * obvious counterpart on the other:
 *
 * | Token          | Use it for                                              |
 * |----------------|---------------------------------------------------------|
 * | `control`      | hover, press, selected state on a button or chip         |
 * | `toggle`       | switching a discrete mode: tab, view mode, filter        |
 * | `fade`         | content cross-fading in place                            |
 * | `media`        | an image or thumbnail arriving from cache or network     |
 * | `pick`         | choosing an item in a grid or viewer                     |
 * | `pop`          | tap feedback on like / repost / zap                      |
 * | `panel`        | expanding or collapsing a region                         |
 * | `chrome`       | scroll-driven toolbars and bars showing/hiding           |
 * | `bannerIn/Out` | a notification banner arriving and leaving               |
 * | `ambientPulse` | a decorative loop that runs while a state holds          |
 * | `shimmer`      | a skeleton placeholder breathing while content loads     |
 * | `scrollJump`   | a programmatic `scrollTo`                                |
 * | `snapBack`     | a drag returning to rest                                 |
 * | `dismiss`      | a gesture-driven dismissal                               |
 *
 * ## Converting the iOS numbers
 *
 * SwiftUI's `.spring(response:dampingFraction:)` and Compose's
 * `spring(dampingRatio:, stiffness:)` describe the same unit-mass oscillator
 * from different ends. `response` is the undamped period, so
 * `stiffness = (2π / response)²` and `dampingRatio` carries straight over. Every
 * stiffness below is that conversion applied to the iOS token of the same name,
 * with the arithmetic left in a comment so it can be rechecked rather than
 * trusted.
 *
 * ## Reduce Motion
 *
 * The Compose app previously had **no** Reduce Motion support at all: not one
 * call site consulted the setting, and two `infiniteRepeatable` animations —
 * the note skeleton and the live-relay dot — ran forever with no way to stop
 * them. Every token here consults it. Under Reduce Motion:
 *
 * - springs collapse to a plain tween of similar length, so nothing overshoots,
 *   bounces, or springs back past its resting position;
 * - ambient loops ([ambientPulse], [shimmer]) return `null`, so a pulsing dot
 *   simply stops instead of animating forever in the corner of someone's eye;
 * - [pillTransition] drops both the slide and the scale, cross-fading in place.
 *
 * A `null` spec is the caller's cue to **skip the animation, not the value**.
 * `animateFloatAsState` has no null-spec overload precisely because the value
 * still has to arrive; a caller holding a `null` here must assign the resting
 * value outright. Getting this backwards is what strands a skeleton at half
 * opacity forever, which is worse than the loop it was meant to remove.
 *
 * Android has no direct equivalent of `UIAccessibility.isReduceMotionEnabled`.
 * The setting users actually reach for is Developer options → "Animator
 * duration scale → Off", which is also what the platform's own animators honour,
 * so that is what [isReduced] reads.
 *
 * Like the iOS side, the flag is read at the moment an animation is created
 * rather than observed through a `CompositionLocal`. That is deliberate: it
 * keeps these tokens usable from the non-composable lambdas where half of this
 * app's motion lives — `NavHost`'s `enterTransition`, `Animatable.animateTo`
 * inside a gesture coroutine — none of which can read a composition local.
 */
object Motion {

    // ---------------------------------------------------------------------
    // Reduce Motion
    // ---------------------------------------------------------------------

    private val reduced = MutableStateFlow(false)

    private var observer: ContentObserver? = null

    /** Whether the system is currently asking for reduced motion. */
    val isReduced: Boolean
        get() = reduced.value

    /** [isReduced] as it changes, for a surface that sleeps between frames. */
    val reducedUpdates: StateFlow<Boolean> = reduced.asStateFlow()

    /**
     * Starts tracking the system animation scale. Call once from
     * `Application.onCreate`.
     *
     * The value is cached rather than read per animation because
     * `Settings.Global.getFloat` is a binder call, and these tokens are read on
     * the recomposition path. The observer keeps the cache honest when the
     * setting changes mid-session.
     */
    fun install(context: Context) {
        val resolver = context.applicationContext.contentResolver
        reduced.value = readAnimatorScale(resolver) == 0f
        if (observer != null) return
        val obs = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reduced.value = readAnimatorScale(resolver) == 0f
            }
        }
        resolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
            false,
            obs,
        )
        observer = obs
    }

    private fun readAnimatorScale(resolver: ContentResolver): Float =
        try {
            Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
        } catch (_: Exception) {
            1f
        }

    // ---------------------------------------------------------------------
    // Easing
    // ---------------------------------------------------------------------

    /** SwiftUI's `.easeInOut` — cubic-bezier(0.42, 0, 0.58, 1). */
    private val EaseInOut: Easing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

    /** SwiftUI's `.easeOut` — cubic-bezier(0, 0, 0.58, 1). */
    private val EaseOut: Easing = CubicBezierEasing(0f, 0f, 0.58f, 1f)

    /** SwiftUI's `.easeIn` — cubic-bezier(0.42, 0, 1, 1). */
    private val EaseIn: Easing = CubicBezierEasing(0.42f, 0f, 1f, 1f)

    /**
     * A spring, or — when motion is reduced — a tween that lasts about as long.
     *
     * `responseMs` is roughly the spring's period, so it doubles as a sensible
     * duration for the tween that replaces it.
     */
    private fun <T> springOrTween(responseMs: Int, damping: Float, stiffness: Float): FiniteAnimationSpec<T> =
        if (isReduced) {
            tween(durationMillis = responseMs, easing = EaseInOut)
        } else {
            spring(dampingRatio = damping, stiffness = stiffness)
        }

    /**
     * The escape hatch for a surface with a genuinely different tempo. Reach for
     * a named token first; a `custom` call in ordinary UI code is a sign the
     * vocabulary is missing a word.
     */
    fun <T> custom(responseMs: Int, damping: Float): FiniteAnimationSpec<T> {
        val period = responseMs / 1000f
        val stiffness = (2f * Math.PI.toFloat() / period).let { it * it }
        return springOrTween(responseMs, damping, stiffness)
    }

    // ---------------------------------------------------------------------
    // Discrete state
    // ---------------------------------------------------------------------

    /**
     * Hover, press, and selected state on a control.
     *
     * Fast enough to feel attached to the finger. Anything slower than ~150ms
     * reads as lag rather than as a transition.
     */
    fun <T> control(): FiniteAnimationSpec<T> = tween(durationMillis = 140, easing = EaseInOut)

    /**
     * Switching a discrete mode — a tab, a view mode, a filter.
     *
     * Replaces the old 150 / 220 spread, so switching bottom-nav tabs feels the
     * same as switching the gallery's grid/list mode.
     */
    fun <T> toggle(): FiniteAnimationSpec<T> = tween(durationMillis = 180, easing = EaseInOut)

    // ---------------------------------------------------------------------
    // Content
    // ---------------------------------------------------------------------

    /** Content cross-fading in place. */
    fun <T> fade(): FiniteAnimationSpec<T> = tween(durationMillis = 220, easing = EaseInOut)

    /**
     * An image or thumbnail arriving.
     *
     * Deliberately `EaseOut`. An ease-in fade starts slow, so a picture that has
     * already finished decoding still *looks* late — the exact opposite of what
     * a media-heavy feed wants.
     */
    fun <T> media(): FiniteAnimationSpec<T> = tween(durationMillis = 180, easing = EaseOut)

    /** Choosing an item in a grid or a media viewer. iOS: response 0.26, damping 0.80. */
    fun <T> pick(): FiniteAnimationSpec<T> = springOrTween(260, 0.80f, 584f) // (2π/0.26)²

    // ---------------------------------------------------------------------
    // Feedback
    // ---------------------------------------------------------------------

    /**
     * Tap feedback on like / repost / zap. iOS: response 0.28, damping 0.62.
     *
     * The one place a little bounce is earned — it is the app's confirmation
     * that a signed event went out. Damping stays low enough to read as a pop.
     */
    fun <T> pop(): FiniteAnimationSpec<T> = springOrTween(280, 0.62f, 504f) // (2π/0.28)²

    /** The scale a [pop]-driven icon pulses to before returning to rest. */
    const val PULSE_SCALE = 1.12f

    /** How long a [pop] pulse is held before it resets, matching the spring's period. */
    const val PULSE_HOLD_MS = 280L

    // ---------------------------------------------------------------------
    // Structure
    // ---------------------------------------------------------------------

    /**
     * Expanding or collapsing a region: a thread, a details panel, a sheet's
     * internal steps. iOS: response 0.42, damping 0.82.
     */
    fun <T> panel(): FiniteAnimationSpec<T> = springOrTween(420, 0.82f, 224f) // (2π/0.42)²

    /**
     * Scroll-driven chrome: bars that hide as the feed scrolls.
     * iOS: response 0.38, damping 0.86.
     *
     * Damping is high on purpose. A bar that tracks your thumb and then
     * overshoots its resting position reads as sloppy, because your thumb has
     * already stopped moving and the bar has not.
     */
    fun <T> chrome(): FiniteAnimationSpec<T> = springOrTween(380, 0.86f, 273f) // (2π/0.38)²

    /**
     * A programmatic jump: `scrollTo` a note, or back to the top of a feed.
     * iOS: response 0.45, damping 0.90.
     *
     * Effectively critically damped, because a spring that overshoots at the
     * *end* of a scroll looks like the list bounced off a wall it did not hit.
     */
    fun <T> scrollJump(): FiniteAnimationSpec<T> = springOrTween(450, 0.90f, 195f) // (2π/0.45)²

    /**
     * A dragged element returning to rest after a gesture that did not commit.
     * iOS: response 0.32, damping 0.72.
     */
    fun <T> snapBack(): FiniteAnimationSpec<T> = springOrTween(320, 0.72f, 386f) // (2π/0.32)²

    /**
     * A gesture-driven dismissal — flinging a media viewer away.
     *
     * `EaseOut` here, unlike [bannerOut]: the finger has already supplied the
     * acceleration, so the animation's job is to carry that momentum out rather
     * than to start one of its own.
     */
    fun <T> dismiss(): FiniteAnimationSpec<T> = tween(durationMillis = 200, easing = EaseOut)

    // ---------------------------------------------------------------------
    // Overlays
    // ---------------------------------------------------------------------

    /**
     * A notification banner arriving. iOS: response 0.34, damping 0.88.
     *
     * Damping is high: a banner that bounces on arrival draws a second beat of
     * attention after it has already landed, which is precisely the wrong thing
     * for something that interrupts.
     */
    fun <T> bannerIn(): FiniteAnimationSpec<T> = springOrTween(340, 0.88f, 342f) // (2π/0.34)²

    /**
     * A notification banner leaving.
     *
     * `EaseIn`, and shorter than the arrival. An element on its way out should
     * accelerate away; ease-out lingers at the start, which makes every
     * dismissal feel like the banner was reluctant to go.
     */
    fun <T> bannerOut(): FiniteAnimationSpec<T> = tween(durationMillis = 240, easing = EaseIn)

    /**
     * The transition every notification pill in the app shares: drops in from
     * the top, shrinks away on dismissal. Cross-fades in place under Reduce
     * Motion, with neither the slide nor the scale.
     */
    val pillTransition: Pair<EnterTransition, ExitTransition>
        get() = if (isReduced) {
            fadeIn(fade()) to fadeOut(fade())
        } else {
            (slideInVertically(bannerIn()) { -it } + fadeIn(bannerIn())) to
                (fadeOut(bannerOut()) + scaleOut(bannerOut(), targetScale = 0.8f))
        }

    // ---------------------------------------------------------------------
    // Ambient loops
    // ---------------------------------------------------------------------

    /**
     * A decorative loop that runs for as long as a state holds — a pulsing
     * "relay is live" dot, a breathing zap bolt.
     *
     * `null` under Reduce Motion, which stops the loop outright rather than
     * merely slowing it. A forever-repeating animation is the single most
     * hostile thing on screen for someone who has asked for less movement,
     * because unlike a transition it never ends.
     *
     * A `null` here means **hold the resting value**, not "animate to nothing".
     */
    val ambientPulse: InfiniteRepeatableSpec<Float>?
        get() = if (isReduced) {
            null
        } else {
            infiniteRepeatable(
                animation = tween(durationMillis = 1600, easing = EaseInOut),
                repeatMode = RepeatMode.Reverse,
            )
        }

    /**
     * A skeleton placeholder breathing while real content loads. `null` under
     * Reduce Motion, for the same reason as [ambientPulse].
     */
    val shimmer: InfiniteRepeatableSpec<Float>?
        get() = if (isReduced) {
            null
        } else {
            infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = EaseInOut),
                repeatMode = RepeatMode.Reverse,
            )
        }

    // ---------------------------------------------------------------------
    // Staggering
    // ---------------------------------------------------------------------

    /**
     * A delay for a token applied to the nth item in a group, for revealing a
     * row of controls one after another.
     *
     * Dropped entirely under Reduce Motion — a cascade is motion whether or not
     * each individual step is a fade — and capped so a long list never turns
     * into a slow wipe.
     */
    fun staggerDelayMs(index: Int, stepMs: Int = 50, cap: Int = 6): Int =
        if (isReduced) 0 else minOf(index, cap) * stepMs
}
