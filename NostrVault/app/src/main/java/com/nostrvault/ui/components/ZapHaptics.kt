package com.nostrvault.ui.components

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * The strike's haptic patterns, ported from iOS `ZapHaptics` (#119) as plain
 * data so they can be rendered and tested without a vibrator.
 *
 * iOS plays them as CoreHaptics patterns: transient taps plus one continuous
 * "thunder" event under a decaying intensity curve. Android's closest match
 * is an amplitude waveform, so [render] samples the same events onto a fixed
 * grid. Sharpness has no Android equivalent before the API 36 envelope
 * effects and is dropped.
 */
object ZapHapticPattern {
    /**
     * One haptic event. [duration] 0 is a transient tap. Times are seconds,
     * [intensity] 0..1, as in `CHHapticEvent`.
     */
    data class Event(val at: Double, val intensity: Float, val duration: Double = 0.0)

    /**
     * A pattern, with an optional linear fade of every event's intensity from
     * 1 at [decayFrom] to 0 [decayLength] seconds later — iOS's
     * `hapticIntensityControl` curve.
     */
    data class Pattern(val events: List<Event>, val decayFrom: Double? = null, val decayLength: Double = 0.0)

    /** A soft rising triple tick while the charge builds. */
    val CHARGE = Pattern(
        listOf(
            Event(0.0, 0.35f),
            Event(0.09, 0.45f),
            Event(0.18, 0.55f),
        ),
    )

    /** The crack, thunder rolling behind it, and aftershocks on the strobes. */
    val STRIKE = Pattern(
        listOf(
            Event(0.0, 1.0f),
            Event(0.02, 0.8f, duration = 0.32),
            Event(ZapBolt.STROBE_STEP * 2, 0.8f),
            Event(ZapBolt.STROBE_STEP * 4, 0.55f),
        ),
        decayFrom = 0.02,
        decayLength = 0.34,
    )

    /** Grid the waveform is sampled on, and how long a transient tap lasts. */
    const val STEP_MS = 10L

    class Waveform(val timings: LongArray, val amplitudes: IntArray) {
        val totalMs: Long get() = timings.sum()
    }

    /**
     * Samples [pattern] into an amplitude waveform. Overlapping events add,
     * as a tap felt on top of a rumble does, clamped to full strength. Equal
     * neighbouring steps are merged.
     */
    fun render(pattern: Pattern): Waveform {
        val endSec = pattern.events.maxOf { it.at + maxOf(it.duration, STEP_MS / 1000.0) }
        val steps = ceil(endSec * 1000 / STEP_MS - 1e-9).toInt()
        val timings = ArrayList<Long>()
        val amplitudes = ArrayList<Int>()
        for (i in 0 until steps) {
            val from = i * STEP_MS / 1000.0
            val to = (i + 1) * STEP_MS / 1000.0
            val mid = (from + to) / 2
            var sum = 0.0
            for (e in pattern.events) {
                val on = if (e.duration > 0) {
                    mid >= e.at && mid < e.at + e.duration
                } else {
                    e.at >= from - 1e-9 && e.at < to - 1e-9
                }
                if (on) sum += e.intensity * control(pattern, maxOf(e.at, mid))
            }
            val amp = (sum.coerceIn(0.0, 1.0) * 255).roundToInt()
            if (amplitudes.isNotEmpty() && amplitudes.last() == amp) {
                timings[timings.size - 1] = timings.last() + STEP_MS
            } else {
                timings.add(STEP_MS)
                amplitudes.add(amp)
            }
        }
        // A trailing silence would only hold the vibrator for nothing.
        while (amplitudes.isNotEmpty() && amplitudes.last() == 0) {
            amplitudes.removeAt(amplitudes.size - 1)
            timings.removeAt(timings.size - 1)
        }
        return Waveform(timings.toLongArray(), amplitudes.toIntArray())
    }

    private fun control(pattern: Pattern, t: Double): Double {
        val from = pattern.decayFrom ?: return 1.0
        if (t <= from) return 1.0
        return (1 - (t - from) / pattern.decayLength).coerceIn(0.0, 1.0)
    }

    /**
     * On/off timings (off, on, off, on…) for a vibrator without amplitude
     * control, mirroring iOS's impact-generator fallback: one light tap for
     * the charge; a heavy hit and a rigid one 60 ms later for the strike. The
     * full waveform there would turn the rumble into 320 ms of full buzz.
     */
    val CHARGE_ON_OFF = longArrayOf(0, 12)
    val STRIKE_ON_OFF = longArrayOf(0, 30, 30, 20)
}

/**
 * Plays [ZapHapticPattern] on this device, as closely as its vibrator allows:
 *
 * 1. amplitude control — the sampled waveform (charge ticks as
 *    `PRIMITIVE_TICK`s where the device has them, which feel crisper);
 * 2. a plain on/off vibrator — short on/off pulses in the iOS fallback's shape;
 * 3. no usable vibrator — `View.performHapticFeedback`, which also needs no
 *    permission and follows the system touch-feedback switch on its own.
 *
 * The system "Touch feedback" switch turns all of it off.
 */
internal object ZapHaptics {

    fun charge(view: View) {
        play(view, strike = false)
    }

    fun strike(view: View) {
        play(view, strike = true)
    }

    private fun play(view: View, strike: Boolean) {
        val context = view.context
        if (!touchFeedbackEnabled(context)) return
        val vibrator = vibrator(context)
        val played = vibrator != null && vibrator.hasVibrator() && runCatching {
            vibrator.play(effect(vibrator, strike))
        }.isSuccess
        if (played) return
        if (strike) {
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            view.postDelayed({
                view.performHapticFeedback(
                    if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM
                    else HapticFeedbackConstants.VIRTUAL_KEY,
                )
            }, 60)
        } else {
            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        }
    }

    private fun effect(vibrator: Vibrator, strike: Boolean): VibrationEffect {
        if (!strike && Build.VERSION.SDK_INT >= 30 &&
            vibrator.areAllPrimitivesSupported(VibrationEffect.Composition.PRIMITIVE_TICK)
        ) {
            val ticks = ZapHapticPattern.CHARGE.events
            val composition = VibrationEffect.startComposition()
            ticks.forEachIndexed { i, tick ->
                // A primitive's delay counts from the end of the previous
                // one; a tick is ~10 ms long, so this lands close to `at`.
                val delay = if (i == 0) 0 else {
                    ((tick.at - ticks[i - 1].at) * 1000).roundToInt() - ZapHapticPattern.STEP_MS.toInt()
                }
                composition.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, tick.intensity, delay.coerceAtLeast(0))
            }
            return composition.compose()
        }
        if (vibrator.hasAmplitudeControl()) {
            val w = ZapHapticPattern.render(if (strike) ZapHapticPattern.STRIKE else ZapHapticPattern.CHARGE)
            return VibrationEffect.createWaveform(w.timings, w.amplitudes, -1)
        }
        return VibrationEffect.createWaveform(
            if (strike) ZapHapticPattern.STRIKE_ON_OFF else ZapHapticPattern.CHARGE_ON_OFF,
            -1,
        )
    }

    private fun Vibrator.play(effect: VibrationEffect) {
        if (Build.VERSION.SDK_INT >= 33) {
            // Touch usage: the system scales it by the user's touch-feedback
            // intensity, and mutes it when that is off.
            vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
        } else {
            @Suppress("DEPRECATION")
            vibrate(
                effect,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
        }
    }

    private fun vibrator(context: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= 31) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    /** From API 33 the touch usage carries the user's setting; before it, read the switch. */
    private fun touchFeedbackEnabled(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 33 || runCatching {
            @Suppress("DEPRECATION")
            Settings.System.getInt(context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) != 0
        }.getOrDefault(true)
}
