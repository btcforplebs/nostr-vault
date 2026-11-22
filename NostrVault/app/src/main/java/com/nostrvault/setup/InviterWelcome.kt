package com.nostrvault.setup

import android.content.Context
import org.json.JSONObject

/**
 * The feed's first card for a new account that came through an invite
 * (setup screens r3, step 5): who brought you in, with Wave back. Set as
 * setup ends; shown on that account's feed for its first day, until waved at
 * or closed. Twin of iOS InviterWelcome (#2417). The rules ([Entry],
 * [start], [inviterFor]) are pure for the tests; [load]/[save] keep the one
 * entry in app-private preferences.
 */
object InviterWelcome {
    private const val PREFS = "nostrvault_inviter_welcome"
    private const val KEY = "entry"

    /** How long the card stays up. */
    const val LIFETIME_MS = 24L * 3600 * 1000

    data class Entry(
        /** The new account (hex). */
        val account: String,
        /** Who invited it (hex). */
        val inviter: String,
        val sinceMs: Long,
        val waved: Boolean = false,
        val closed: Boolean = false,
    )

    /** The entry for setup ending on [account] with [inviter] first in its follows; null clears it. */
    fun start(account: String, inviter: String?, nowMs: Long): Entry? {
        val acct = account.lowercase()
        val inv = inviter?.lowercase() ?: return null
        if (!isHex(acct) || !isHex(inv) || inv == acct) return null
        return Entry(acct, inv, nowMs)
    }

    /** The inviter to show on [account]'s feed now, if any. */
    fun inviterFor(entry: Entry?, account: String, nowMs: Long): String? {
        val e = entry ?: return null
        if (e.account != account.lowercase() || e.closed || e.waved) return null
        if (nowMs < e.sinceMs || nowMs - e.sinceMs >= LIFETIME_MS) return null
        return e.inviter
    }

    /** The wave: a short public note that mentions the inviter. */
    fun waveContent(inviterNpub: String): String = "👋 nostr:$inviterNpub"
    fun waveTags(inviter: String): List<List<String>> = listOf(listOf("p", inviter.lowercase()))

    private fun isHex(s: String) = s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' }

    // ── Storage ───────────────────────────────────────────────────

    fun load(context: Context): Entry? {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return null
        return runCatching {
            val o = JSONObject(raw)
            Entry(o.getString("account"), o.getString("inviter"), o.getLong("since"), o.optBoolean("waved"), o.optBoolean("closed"))
        }.getOrNull()
    }

    fun save(context: Context, entry: Entry?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (entry == null) {
            prefs.remove(KEY)
        } else {
            val o = JSONObject()
                .put("account", entry.account).put("inviter", entry.inviter).put("since", entry.sinceMs)
                .put("waved", entry.waved).put("closed", entry.closed)
            prefs.putString(KEY, o.toString())
        }
        prefs.apply()
    }

    fun markWaved(context: Context) { load(context)?.let { save(context, it.copy(waved = true)) } }
    fun close(context: Context) { load(context)?.let { save(context, it.copy(closed = true)) } }
}
