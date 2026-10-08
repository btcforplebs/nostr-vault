package com.nostrvault.tutorials

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private class PrefsTutorialStore(private val prefs: SharedPreferences) : TutorialStore {
    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun putString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}

/**
 * The app's one tutorial runner (iOS `TutorialCenter`). Pages ask it to
 * start their tutorial; [TutorialStage] draws the cards for the active one.
 *
 * Fill your vault draws its own guide: it shows while
 * `isActive(FILL_YOUR_VAULT)` and calls [finish] or [skip] itself.
 *
 * `account` is always the active account's hex pubkey: Fill your vault is
 * about whose follows you're looking at, and the page tutorials' gate reads
 * that same account's Fill your vault status.
 */
@Stable
object TutorialCenter {
    private var progress = TutorialProgress(object : TutorialStore {
        override fun getString(key: String): String? = null
        override fun putString(key: String, value: String?) {}
    })

    private val _active = MutableStateFlow<TutorialID?>(null)
    val active: StateFlow<TutorialID?> = _active.asStateFlow()

    private val _stepIndex = MutableStateFlow(0)
    val stepIndex: StateFlow<Int> = _stepIndex.asStateFlow()

    /** Bumped on every saved status change, so Settings re-reads and pages
     *  re-check their start (Fill your vault marked done quietly). */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision.asStateFlow()

    /** Where each [tutorialAnchor] is, in root coordinates. */
    val anchors = mutableStateMapOf<String, Rect>()

    fun init(context: Context) {
        progress = TutorialProgress(
            PrefsTutorialStore(context.getSharedPreferences("tutorials", Context.MODE_PRIVATE)),
        )
    }

    fun isActive(id: TutorialID): Boolean = _active.value == id

    /** See [TutorialProgress.held]. Fill your vault's coordinator sets it. */
    var held: Boolean
        get() = progress.held
        set(value) { progress.held = value }

    fun status(id: TutorialID, account: String): TutorialStatus = progress.status(id, account)

    fun startIfEligible(id: TutorialID, account: String) {
        if (!id.isAvailable || !progress.startIfEligible(id, account)) return
        _stepIndex.value = 0
        publish()
    }

    fun replay(id: TutorialID) {
        if (!id.isAvailable) return
        progress.replay(id)
        _stepIndex.value = 0
        publish()
    }

    fun finish(id: TutorialID, account: String) {
        progress.finish(id, account)
        publish(saved = true)
    }

    /** Done without being shown, so the page on screen may start its own. */
    fun finishQuietly(id: TutorialID, account: String) {
        progress.finish(id, account)
        publish(saved = true)
    }

    fun skip(id: TutorialID, account: String) {
        progress.skip(id, account)
        publish(saved = true)
    }

    fun resetAll(account: String) {
        progress.resetAll(account)
        publish(saved = true)
    }

    // ── Cards ─────────────────────────────────────────────────────

    fun currentStep(): TutorialStep? {
        val steps = _active.value?.steps ?: return null
        return steps.getOrNull(_stepIndex.value)
    }

    fun isLastStep(): Boolean {
        val steps = _active.value?.steps ?: return true
        return _stepIndex.value >= steps.size - 1
    }

    fun next(account: String) {
        val id = _active.value ?: return
        if (isLastStep()) finish(id, account) else _stepIndex.value += 1
    }

    fun back() {
        if (_stepIndex.value > 0) _stepIndex.value -= 1
    }

    private fun publish(saved: Boolean = false) {
        _active.value = progress.active
        if (saved) _revision.value += 1
    }
}

/** Marks this as something a tutorial card can point at. */
fun Modifier.tutorialAnchor(name: String): Modifier = composed {
    DisposableEffect(name) {
        onDispose { TutorialCenter.anchors.remove(name) }
    }
    onGloballyPositioned { coords ->
        val bounds = coords.boundsInRoot()
        if (TutorialCenter.anchors[name] != bounds) TutorialCenter.anchors[name] = bounds
    }
}
