package com.nostrvault.data.local

import android.content.Context
import com.nostrvault.data.model.AccountUnread
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
) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(load())
    val state: StateFlow<AccountUnread> = _state

    /** A relay log line; anything but a NOTIFY marker is ignored. */
    fun onLogLine(raw: String) {
        val idx = raw.indexOf(MARKER)
        if (idx < 0) return
        update { it.record(raw.substring(idx + MARKER.length)) }
    }

    fun markSeen(hex: String) = update { it.markSeen(hex) }

    @Synchronized
    private fun update(change: (AccountUnread) -> AccountUnread) {
        val before = _state.value
        val after = change(before)
        if (after == before) return
        _state.value = after
        prefs.edit().putString(KEY, encode(after)).apply()
    }

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
