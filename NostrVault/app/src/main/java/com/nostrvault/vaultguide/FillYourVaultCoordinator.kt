package com.nostrvault.vaultguide

import android.content.Context
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.service.FeedService
import com.nostrvault.tutorials.TutorialCenter
import com.nostrvault.tutorials.TutorialID
import com.nostrvault.tutorials.TutorialStatus
import com.nostrvault.tutorials.TutorialStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Applies [FillYourVaultRule] to the active account's follow list: starts the
 * guide for a new account, marks it done without showing it for an account
 * that already follows 5, and finishes it when the vault fills. Also keeps
 * Vault Master once earned. iOS: FillYourVaultCoordinator.swift.
 *
 * [init] at app start (preferences only), [start] once FeedService exists.
 */
object FillYourVaultCoordinator {
    private var masterStore: VaultMasterStore? = null
    private var started = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    /** Count the last time the rule ran, per account; null before the list is known. */
    private var lastCount: Pair<String, Int>? = null

    private val _meter = MutableStateFlow(VaultMeter.of(emptyList(), "", false))
    /** The meter for the active account. The guide's views read it. */
    val meter: StateFlow<VaultMeter> = _meter.asStateFlow()

    /** Set when this account first reaches Vault Master; the meter plays the bolt once and clears it. */
    val celebrateVaultMaster = MutableStateFlow(false)

    fun init(context: Context) {
        if (masterStore != null) return
        val prefs = context.getSharedPreferences("vault_guide", Context.MODE_PRIVATE)
        masterStore = VaultMasterStore(object : TutorialStore {
            override fun getString(key: String): String? = prefs.getString(key, null)
            override fun putString(key: String, value: String?) {
                prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
            }
        })
    }

    fun start(feedService: FeedService, configStore: ConfigStore) {
        if (started) return
        started = true
        scope.launch {
            combine(
                feedService.followedPubkeys,
                feedService.followListIsKnown,
                configStore.activeAccountHexPubkey,
            ) { follows, known, account -> Triple(follows, known, account) }
                .collect { (follows, known, account) -> update(follows, known, account) }
        }
    }

    /** Closing the guide by hand: done past 5, skipped below. */
    fun close(account: String) {
        when (FillYourVaultRule.onClose(_meter.value.count)) {
            TutorialStatus.DONE -> TutorialCenter.finish(TutorialID.FILL_YOUR_VAULT, account)
            else -> TutorialCenter.skip(TutorialID.FILL_YOUR_VAULT, account)
        }
    }

    private fun update(follows: List<String>, listKnown: Boolean, account: String) {
        val store = masterStore
        var meter = VaultMeter.of(follows, account, store?.isEarned(account) == true)
        val known = listKnown && account.isNotEmpty()
        val previous = lastCount?.takeIf { it.first == account }?.second
        if (known) lastCount = account to meter.count

        if (known && store?.record(meter, account) == true) {
            meter = VaultMeter.of(follows, account, true)
            celebrateVaultMaster.value = true
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
            FillYourVaultRule.Action.FINISH_SILENTLY, FillYourVaultRule.Action.FINISH ->
                TutorialCenter.finish(id, account)
        }
    }
}
