package com.nostrvault.data.model

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The Vault tab's red dot: the set of Vault lists with news, one set per
 * account, lit only for news (Logen 2026-11-13: "on return to the app the
 * Vault tab button is red"). Android twin of iOS RelayProcessManager+NewsDot
 * (#2034); RelayForegroundService holds the one instance.
 *
 * The relay logs "new … in your inbox" for every event from others it
 * stores, for any account on the device, and on return it stores the whole
 * catch-up, including likes already seen elsewhere. So while the Vault list
 * reads the inbox into memory ([judged]), a landed line only proposes a
 * list; the list's next read [settle]s it: lit when an event from someone
 * else, tagging the account on screen and dated after its last visit to the
 * list, came back. With nothing reading the inbox the line decides, as before.
 */
class VaultNewsDot {
    private val _modes = MutableStateFlow<Set<VaultMode>>(emptySet())
    val modes: StateFlow<Set<VaultMode>> = _modes.asStateFlow()

    private val accounts = VaultNewsAccounts<VaultMode>()
    private var account = ""
    private var pending: Set<VaultMode> = emptySet()
    /** How many readers judge proposals now (each Vault list ViewModel alive). */
    private var judges = 0

    /** The account the dot is for now (lowercase hex; empty before the first). */
    @Synchronized
    fun account(): String = account

    /** The relay stored something for [mode]'s list. */
    @Synchronized
    fun land(mode: VaultMode) {
        if (mode in _modes.value) return
        if (judges > 0) pending = pending + mode else _modes.value = _modes.value + mode
    }

    /** The lists proposed and not yet settled. */
    @Synchronized
    fun proposed(): Set<VaultMode> = pending

    /**
     * A read for [forAccount] done: of [asked] (taken from [proposed] before it
     * began) the lists [isNews] says yes to light; all of them are settled.
     */
    @Synchronized
    fun settle(asked: Set<VaultMode>, forAccount: String, isNews: (VaultMode) -> Boolean) {
        if (asked.isEmpty()) return
        pending = pending - asked
        // Switched away meanwhile: that account's lists aren't on this dot now.
        if (forAccount.lowercase() != account) return
        val lit = asked.filter { it !in _modes.value && isNews(it) }
        if (lit.isNotEmpty()) _modes.value = _modes.value + lit
    }

    /**
     * A reader of the inbox into memory came ([on]) or went. While one is
     * there, lines only propose; with none left the line decides again.
     */
    @Synchronized
    fun setJudged(on: Boolean) {
        judges = if (on) judges + 1 else maxOf(0, judges - 1)
        if (judges == 0 && pending.isNotEmpty()) {
            _modes.value = _modes.value + pending
            pending = emptySet()
        }
    }

    /** [mode] is on screen: what came into it has been seen. "Vault" sees every list. */
    @Synchronized
    fun viewed(mode: VaultMode) {
        val next = if (mode == VaultMode.ACTIVITY) emptySet() else _modes.value - mode
        if (next != _modes.value) _modes.value = next
    }

    /** The active account is now [to]: the old one keeps its dot for when you come back. */
    @Synchronized
    fun switchAccount(to: String) {
        val t = to.lowercase()
        if (t == account) return
        val next = accounts.switchAccount(account, t, _modes.value)
        account = t
        pending = emptySet()
        if (next != _modes.value) _modes.value = next
    }
}
