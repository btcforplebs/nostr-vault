package com.nostrvault.service

import android.content.Context
import android.content.SharedPreferences

/**
 * Ids of the list events this app signed on this device, so the wipe alarm
 * (ListWipeAlarmRule) stays quiet about the owner's own edits. Recorded at the
 * one signing choke point (NostrService.signEventAsyncImpl), for protected
 * kinds only; the newest [KEEP] are kept. Per device: an edit made in Nostr
 * Vault on another device is not in here (docs/LIST_WIPE_ALARM.md, limits).
 * Twin of iOS `OwnListEdits.swift`.
 */
object OwnListEdits {
    const val PREFS = "own_list_edits"
    private const val IDS = "ids"
    const val KEEP = 500

    @Volatile private var prefs: SharedPreferences? = null
    private val lock = Any()

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    /** Records [id] when [kind] is a list the vault keeps history for. */
    fun record(kind: Int, id: String) {
        if (!ListShrinkRule.isProtected(kind) || id.isEmpty()) return
        val p = prefs ?: return
        synchronized(lock) {
            val next = appended(read(p), id)
            p.edit().putString(IDS, next.joinToString(",")).apply()
        }
    }

    fun ids(): Set<String> = prefs?.let { synchronized(lock) { read(it).toSet() } }.orEmpty()

    private fun read(p: SharedPreferences): List<String> =
        p.getString(IDS, "").orEmpty().split(',').filter { it.isNotEmpty() }

    /** [list] with [id] last, once, capped to the newest [KEEP]. Pure, for tests. */
    internal fun appended(list: List<String>, id: String): List<String> =
        (list.filter { it != id } + id).takeLast(KEEP)
}
