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
 * Vault Master once earned, and moves the "Fill your feed" guide between its
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

    /** Set when this account first reaches Vault Master; the meter plays the bolt once and clears it. */
    val celebrateVaultMaster = MutableStateFlow(false)

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

    /** Topics picked in this run, so "Only my web of trust" drops just those. */
    private var pickedTopics: List<String> = emptyList()

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
                    pickedTopics = emptyList()
                    _phase.value = FillYourFeedGuide.entryPhase(_meterOn.value)
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
        _phase.value = FillYourFeedPhase.TOPICS
    }

    /** Topics: "Show posts". Follows the picked hashtags and opens the topic feed behind the hint. */
    fun showPosts(topics: List<String>) {
        pickedTopics = topics
        val service = interests
        if (service != null) {
            val new = topics.filter { !service.isFollowing(it) }
            if (new.isNotEmpty()) scope.launch { service.setFollowing(new, true) }
        }
        feed?.switchMode(FeedMode.HASHTAGS)
        _phase.value = FillYourFeedPhase.HINT
    }

    /** Hint: "Got it". */
    fun dismissHint() { _phase.value = FillYourFeedPhase.BROWSING }

    /** "Your feed is ready": go to Following. [keepTopics] false unfollows the hashtags picked in this run. */
    fun goToFollowing(keepTopics: Boolean) {
        val service = interests
        if (!keepTopics && pickedTopics.isNotEmpty() && service != null) {
            val topics = pickedTopics
            scope.launch { service.setFollowing(topics, false) }
        }
        feed?.switchMode(FeedMode.FOLLOWING)
        meterCollapsed.value = true
        _phase.value = FillYourFeedPhase.BROWSING
    }

    /** The bolt has crossed the meter: show the Vault Master card. */
    fun showMasterCard() {
        celebrateVaultMaster.value = false
        meterCollapsed.value = false
        _phase.value = FillYourFeedPhase.MASTER
    }

    fun dismissMasterCard() { _phase.value = FillYourFeedPhase.BROWSING }

    /** Skip, "Not now" or "Hide the meter": the guide closes and the meter goes away. */
    fun closeGuide() {
        if (TutorialCenter.isActive(TutorialID.FILL_YOUR_VAULT)) close(account)
        meterStore?.set(false, account)
        _meterOn.value = false
        profileCardPubkey.value = null
        _phase.value = FillYourFeedPhase.OFF
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
        if (!TutorialCenter.isActive(TutorialID.FILL_YOUR_VAULT)) _phase.value = FillYourFeedPhase.OFF
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
            if (_meterOn.value) celebrateVaultMaster.value = true
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
            FillYourVaultRule.Action.FINISH_SILENTLY -> TutorialCenter.finish(id, account)
            FillYourVaultRule.Action.FINISH -> {
                TutorialCenter.finish(id, account)
                profileCardPubkey.value = null
                _phase.value = FillYourFeedPhase.READY
            }
        }
    }
}
