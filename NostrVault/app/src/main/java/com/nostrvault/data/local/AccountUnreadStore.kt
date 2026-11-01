package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.VaultContentFilter
import com.nostrvault.relay.HavenBridge
import com.nostrvault.service.FeedService
import dagger.Lazy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps [AccountUnread] across launches and publishes it to the account
 * switcher. Fed by the relay's NOTIFY markers (RelayForegroundService's log
 * sink), emptied by the Vault list (VaultActivityViewModel.visit). iOS:
 * AccountUnreadStore.swift.
 */
@Singleton
class AccountUnreadStore @Inject constructor(
    @ApplicationContext context: Context,
    private val configStore: ConfigStore,
    // Lazy: the trust graph is only asked for when a marker arrives.
    private val feedService: Lazy<FeedService>,
) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(load())
    val state: StateFlow<AccountUnread> = _state

    /** A relay log line; anything but a NOTIFY marker is ignored. */
    fun onLogLine(raw: String) {
        val idx = raw.indexOf(MARKER)
        if (idx < 0) return
        val body = raw.substring(idx + MARKER.length)
        // The badge counts nothing the Vault list hides. Judged before the
        // lock: the trust graph lookup has no business inside it.
        val marker = AccountUnread.parseMarker(body) ?: return
        if (isOwnAccountTag(marker.recipient, marker.author)) return
        if (!listShows(marker)) return
        update { it.record(body) }
    }

    /**
     * Whether the recipient's Vault list will draw [marker], with the inputs
     * VaultActivityViewModel builds that list from (its blocks, the whitelist,
     * the Relay-tab trust graph, Zaps Only).
     */
    private fun listShows(marker: AccountUnread.Marker): Boolean {
        val config = configStore.config.value
        val npub = runCatching { HavenBridge.hexToNpub(marker.recipient) }.getOrNull()
        val blocked = npub?.let { config.blockedFor(it) }.orEmpty().mapNotNull(::hexOf).toSet()
        // Only replies, quotes and mentions are judged by network; skip the graph otherwise.
        val judgesNetwork = marker.type == "reply" || marker.type == "quote" || marker.type == "mention"
        val whitelist = if (judgesNetwork) config.whitelistedNpubs?.mapNotNull(::hexOf)?.toSet().orEmpty() else emptySet()
        val trusted = if (judgesNetwork) feedService.get().relayTabTrustedPubkeys() else emptySet()
        return AccountUnread.listShows(
            marker,
            zapsOnly = config.zapsOnlyMode,
            isBlocked = { it in blocked },
            isOutside = { VaultContentFilter.isOutside(it, marker.recipient, whitelist, trusted) },
        )
    }

    /**
     * One of your accounts tagging another while that switch is off
     * (AccountUnread.hidesOwnAccountTag): nothing counts, lights or alerts.
     */
    fun isOwnAccountTag(recipient: String, author: String): Boolean {
        val config = configStore.config.value
        if (config.notifyOwnAccountTags) return false
        val accounts = config.allAccountNpubs().mapNotNull(::hexOf).toSet()
        return AccountUnread.hidesOwnAccountTag(author, recipient, accounts, notify = false)
    }

    /** The kinds in a poll's markers that only came as own-account tags (the Vault tab dot skips them). */
    fun ownAccountOnlyKinds(markers: List<String>): Set<Int> =
        if (markers.isEmpty() || configStore.config.value.notifyOwnAccountTags) emptySet()
        else AccountUnread.ownAccountOnlyKinds(markers, ::isOwnAccountTag)

    fun markSeen(hex: String) = update { it.markSeen(hex) }

    @Synchronized
    private fun update(change: (AccountUnread) -> AccountUnread) {
        val before = _state.value
        val after = change(before)
        if (after == before) return
        _state.value = after
        prefs.edit().putString(KEY, encode(after)).apply()
    }

    private fun hexOf(npub: String): String? =
        if (npub.startsWith("npub1")) runCatching { HavenBridge.decodeNpub(npub) }.getOrNull() else null

    private fun load(): AccountUnread = try {
        val json = JSONObject(prefs.getString(KEY, null) ?: return AccountUnread())
        AccountUnread(json.keys().asSequence().associateWith { hex ->
            val arr = json.getJSONArray(hex)
            List(arr.length()) { arr.getString(it) }
        })
    } catch (_: org.json.JSONException) {
        AccountUnread()
    }

    private fun encode(u: AccountUnread): String =
        JSONObject().apply { u.ids.forEach { (hex, ids) -> put(hex, JSONArray(ids)) } }.toString()

    private companion object {
        const val PREFS_NAME = "account_unread"
        const val KEY = "ids"
        const val MARKER = "🔔NOTIFY|"
    }
}
