package com.nostrvault.vaultguide

import android.content.Context
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedMode
import com.nostrvault.service.FeedService
import com.nostrvault.service.InterestListService
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.tutorials.TutorialStatus
import com.nostrvault.tutorials.TutorialStore
import com.nostrvault.tutorials.next
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Applies [FillYourVaultRule] to the active account's follow list: starts the
 * guide for a new account, marks it done without showing it for an account
 * that already follows 5, and finishes it when the feed fills. Also keeps
 * the web of trust (5 follows) once built, and moves the "Fill your feed" guide between its
 * screens ([phase]). `FillYourFeedOverlay` draws what this publishes.
 * iOS: FillYourVaultCoordinator.swift.
 *
 * [init] at app start (preferences only), [start] once FeedService exists.
 */
object FillYourVaultCoordinator {
    private var masterStore: VaultMasterStore? = null
    private var meterStore: FeedMeterStore? = null
    private var started = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    /** Count the last time the rule ran, per account; null before the list is known. */
    private var lastCount: Pair<String, Int>? = null
    private var feed: FeedService? = null
    private var interests: InterestListService? = null
    private var account = ""

    private val _meter = MutableStateFlow(VaultMeter.of(emptyList(), "", false))
    /** The meter for the active account. The guide's views read it. */
    val meter: StateFlow<VaultMeter> = _meter.asStateFlow()

    private val _celebrateVaultMaster = MutableStateFlow(false)
    /** Set when this account first builds its web of trust; the meter plays
     *  the bolt once, then shows the "built" card ([showReadyCard]). */
    val celebrateVaultMaster: StateFlow<Boolean> = _celebrateVaultMaster.asStateFlow()

    private val _phase = MutableStateFlow(FillYourFeedPhase.OFF)
    /** Which of the guide's screens is up. */
    val phase: StateFlow<FillYourFeedPhase> = _phase.asStateFlow()

    private val _meterOn = MutableStateFlow(false)
    /** Whether the meter is on for this account (see [FeedMeterStore]). */
    val meterOn: StateFlow<Boolean> = _meterOn.asStateFlow()

    /** The meter folded down to its pill. */
    val meterCollapsed = MutableStateFlow(false)

    /**
     * The open meter's measured height. Post rises by it and the feed
     * scrolls clear of it (Tory: Post keeps priority); zero when folded.
     */
    val meterHeight = MutableStateFlow(0.dp)

    /** The person whose small profile card is open. */
    val profileCardPubkey = MutableStateFlow<String?>(null)

    /** True while the meter is drawn. */
    val meterShowing: Boolean get() = FillYourFeedGuide.showsMeter(_phase.value, _meterOn.value)

    fun init(context: Context) {
        if (masterStore != null) return
        val prefs = context.getSharedPreferences("vault_guide", Context.MODE_PRIVATE)
        val store = object : TutorialStore {
            override fun getString(key: String): String? = prefs.getString(key, null)
            override fun putString(key: String, value: String?) {
                prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
            }
        }
        masterStore = VaultMasterStore(store)
        meterStore = FeedMeterStore(store)
    }

    /** [activeAccount] is the same flow the tutorial cards and Feeds start key on. */
    fun start(feedService: FeedService, interestListService: InterestListService, activeAccount: Flow<String>) {
        if (started) return
        started = true
        feed = feedService
        interests = interestListService
        scope.launch {
            combine(
                feedService.followedPubkeys,
                feedService.followListIsKnown,
                activeAccount,
            ) { follows, known, account -> Triple(follows, known, account) }
                .collect { (follows, known, account) -> update(follows, known, account) }
        }
        scope.launch {
            activeAccount.distinctUntilChanged().collect { loadMeterState(it) }
        }
        // The engine starts the guide (or Settings replays it): open it.
        scope.launch {
            var wasActive = false
            TutorialCenter.active.collect { active ->
                val isOn = active == TutorialID.FILL_YOUR_VAULT
                if (isOn && !wasActive) {
                    val entry = FillYourFeedGuide.entryPhase(_meterOn.value)
                    setPhase(entry)
                    // Back mid-guide after a relaunch: their topic feed, where
                    // they were finding people (iOS: FeedService's no-follows path).
                    if (entry == FillYourFeedPhase.BROWSING && _meter.value.count < VaultMeter.GOAL &&
                        followedTopics().isNotEmpty()
                    ) {
                        feed?.switchMode(FeedMode.HASHTAGS)
                    }
                }
                wasActive = isOn
            }
        }
    }

    // ── Guide steps ───────────────────────────────────────────────

    /** Intro: "Let's fill it". */
    fun beginFilling() {
        meterStore?.set(true, account)
        _meterOn.value = true
        meterCollapsed.value = false
        setPhase(FillYourFeedPhase.TOPICS)
    }

    /** Topics: "Show posts". Follows the picked hashtags and opens the topic feed behind the hint. */
    fun showPosts(topics: List<String>) {
        val service = interests
        if (service != null) {
            val new = topics.filter { !service.isFollowing(it) }
            if (new.isNotEmpty()) scope.launch { service.setFollowing(new, true) }
        }
        feed?.switchMode(FeedMode.HASHTAGS)
        setPhase(FillYourFeedPhase.HINT)
    }

    /** Hint: "Got it". */
    fun dismissHint() { setPhase(FillYourFeedPhase.BROWSING) }

    /**
     * "Your web of trust is built": open Discover to find more people, put
     * the meter away and start the Feeds tutorial there. The picked topics
     * stay followed (Logen: keep them, don't ask).
     */
    fun goToDiscover() {
        feed?.switchMode(FeedMode.DISCOVERY)
        closeGuide()
        TutorialID.FILL_YOUR_VAULT.next?.let { TutorialCenter.replay(it) }
    }

    /** The bolt has crossed the meter: show the web-of-trust card. */
    fun showReadyCard() {
        setCelebrate(false)
        meterCollapsed.value = false
        setPhase(FillYourFeedPhase.READY)
    }

    /** Skip, "Not now" or "Hide the meter": the guide closes and the meter goes away. */
    fun closeGuide() {
        if (TutorialCenter.isActive(TutorialID.FILL_YOUR_VAULT)) close(account)
        meterStore?.set(false, account)
        _meterOn.value = false
        profileCardPubkey.value = null
        setPhase(FillYourFeedPhase.OFF)
    }

    /** Closing the guide by hand: done past 5, skipped below. */
    fun close(account: String) {
        when (FillYourVaultRule.onClose(_meter.value.count)) {
            TutorialStatus.DONE -> TutorialCenter.finish(TutorialID.FILL_YOUR_VAULT, account)
            else -> TutorialCenter.skip(TutorialID.FILL_YOUR_VAULT, account)
        }
    }

    /** Hashtags this account already follows: they start picked. */
    fun followedTopics(): List<String> = interests?.hashtags?.value.orEmpty()

    /** "People your follows bring into your web of trust". */
    suspend fun countExtendedNetwork(): Int = feed?.countExtendedNetwork() ?: 0

    // ── State ─────────────────────────────────────────────────────

    private fun loadMeterState(account: String) {
        _meterOn.value = meterStore?.isOn(account) == true
        meterCollapsed.value = _meter.value.count >= VaultMeter.GOAL
        profileCardPubkey.value = null
        if (!TutorialCenter.isActive(TutorialID.FILL_YOUR_VAULT)) setPhase(FillYourFeedPhase.OFF)
    }

    private fun setPhase(phase: FillYourFeedPhase) {
        _phase.value = phase
        holdOtherTutorials()
    }

    private fun setCelebrate(on: Boolean) {
        _celebrateVaultMaster.value = on
        holdOtherTutorials()
    }

    /** Fill your vault is done once 5 are followed, but its bolt and
     *  "built" card are still up: no page tutorial may start over them. */
    private fun holdOtherTutorials() {
        TutorialCenter.held = _celebrateVaultMaster.value || _phase.value == FillYourFeedPhase.READY
    }

    private fun update(follows: List<String>, listKnown: Boolean, account: String) {
        this.account = account
        val store = masterStore
        var meter = VaultMeter.of(follows, account, store?.isEarned(account) == true)
        val known = listKnown && account.isNotEmpty()
        val previous = lastCount?.takeIf { it.first == account }?.second
        if (known) lastCount = account to meter.count

        if (known && store?.record(meter, account) == true) {
            meter = VaultMeter.of(follows, account, true)
            // Only the guide's people get the bolt.
            if (_meterOn.value) setCelebrate(true)
        }
        _meter.value = meter

        val id = TutorialID.FILL_YOUR_VAULT
        when (FillYourVaultRule.onFollowsChanged(
            listKnown = known,
            previousCount = previous,
            count = meter.count,
            status = TutorialCenter.status(id, account),
            isActive = TutorialCenter.isActive(id),
        )) {
            FillYourVaultRule.Action.NONE -> Unit
            FillYourVaultRule.Action.START -> TutorialCenter.startIfEligible(id, account)
            FillYourVaultRule.Action.FINISH_SILENTLY -> TutorialCenter.finishQuietly(id, account)
            FillYourVaultRule.Action.FINISH -> {
                TutorialCenter.finish(id, account)
                profileCardPubkey.value = null
                // With the meter up, the bolt plays first and opens the card.
                if (!_celebrateVaultMaster.value) setPhase(FillYourFeedPhase.READY)
            }
        }
    }
}
