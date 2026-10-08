package com.nostrvault.tutorials

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateListOf
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

    /** Bumped when a status changes without the person closing anything:
     *  Fill your vault marked done quietly (an account that already follows
     *  people), or Settings resetting them all. Pages key their start on it,
     *  so the page on screen starts its tutorial then. Skip or Done doesn't
     *  bump it: the next tutorial waits for the person's next visit to a
     *  page, not the screen they just closed one on (iOS #414). */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision.asStateFlow()

    /** Bumped on every saved status, so Settings re-reads. */
    private val _saves = MutableStateFlow(0)
    val saves: StateFlow<Int> = _saves.asStateFlow()

    /** Where each [tutorialAnchor] is, in its layer's root coordinates. */
    val anchors = mutableStateMapOf<String, PlacedAnchor>()

    /** The [TutorialStage]s on screen, bottom to top: the app's own, then
     *  one per open sheet (a sheet is its own window, so the app's stage
     *  can't draw over it). A card with nothing to point at goes on the top
     *  one. */
    val layers = mutableStateListOf<String>()

    /** Whether a wallet is linked. Set by the app from its config: Wallet
     *  Connect's cards point at the empty wallet, which isn't there then. */
    var walletLinked: () -> Boolean = { false }

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
        publish(saved = true, pagesRecheck = false)
    }

    /** Done without being shown, so the page on screen may start its own. */
    fun finishQuietly(id: TutorialID, account: String) {
        progress.finish(id, account)
        publish(saved = true)
    }

    fun skip(id: TutorialID, account: String) {
        progress.skip(id, account)
        publish(saved = true, pagesRecheck = false)
    }

    fun resetAll(account: String) {
        progress.resetAll(account)
        publish(saved = true)
    }

    /** The tutorial the last card of [id] hands over to (iOS
     *  `next(after:)`). Wallet Connect is passed over once a wallet is
     *  linked. */
    fun nextAfter(id: TutorialID): TutorialID? {
        val next = id.next ?: return null
        return if (next == TutorialID.WALLET_CONNECT && walletLinked()) nextAfter(next) else next
    }

    /** Closes the active tutorial as done and starts the one after it. */
    fun startNext(account: String) {
        val id = _active.value ?: return
        val next = nextAfter(id) ?: return
        finish(id, account)
        replay(next)
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

    private fun publish(saved: Boolean = false, pagesRecheck: Boolean = saved) {
        _active.value = progress.active
        if (saved) _saves.value += 1
        if (pagesRecheck) _revision.value += 1
    }
}

/** An anchor's bounds and the [TutorialStage] layer it was laid out in. */
data class PlacedAnchor(val bounds: Rect, val layer: String)

/** The app's own stage, in MainActivity's root box. */
const val ROOT_TUTORIAL_LAYER = "root"

/** Which [TutorialStage] the anchors under it belong to. A sheet that holds
 *  anchors provides its own and draws its own stage. */
val LocalTutorialLayer = compositionLocalOf { ROOT_TUTORIAL_LAYER }

/** Marks this as something a tutorial card can point at. */
fun Modifier.tutorialAnchor(name: String): Modifier = composed {
    val layer = LocalTutorialLayer.current
    DisposableEffect(name, layer) {
        onDispose {
            if (TutorialCenter.anchors[name]?.layer == layer) TutorialCenter.anchors.remove(name)
        }
    }
    onGloballyPositioned { coords ->
        val placed = PlacedAnchor(coords.boundsInRoot(), layer)
        if (TutorialCenter.anchors[name] != placed) TutorialCenter.anchors[name] = placed
    }
}
