package com.nostrvault.data.local

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * When the vault last did the things that keep it complete and safe. The
 * Vault Dashboard shows these as "last ran" lines; nothing else stored them.
 * Device-wide: there is one vault per device, whichever account is active.
 * Port of iOS `VaultHistory` (UserDefaults, same keys).
 *
 * Pure Kotlin over a [Store], so it is unit-testable; [VaultHistoryStore] is
 * the app's SharedPreferences-backed instance.
 */
class VaultHistory(
    private val store: Store,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** Epoch milliseconds by key; null when never written. */
    interface Store {
        fun read(key: String): Long?
        fun write(key: String, value: Long)
    }

    enum class Entry(val key: String) {
        /** A notes import finished (dashboard or Settings › Import). */
        NOTES_IMPORT("haven.vault.lastNotesImport"),
        /** A notes backup file was made (dashboard or Settings › Backup). */
        NOTES_BACKUP("haven.vault.lastNotesBackup"),
        /** A media backup file was made (dashboard or Settings › Backup). */
        MEDIA_BACKUP("haven.vault.lastMediaBackup"),
        /** A media import (Blossom mirror) run finished. */
        MEDIA_IMPORT("haven.vault.lastMediaImport"),
    }

    /** Every entry's last time, epoch milliseconds, null for never. */
    data class Snapshot(
        val notesImport: Long? = null,
        val notesBackup: Long? = null,
        val mediaBackup: Long? = null,
        val mediaImport: Long? = null,
    ) {
        operator fun get(entry: Entry): Long? = when (entry) {
            Entry.NOTES_IMPORT -> notesImport
            Entry.NOTES_BACKUP -> notesBackup
            Entry.MEDIA_BACKUP -> mediaBackup
            Entry.MEDIA_IMPORT -> mediaImport
        }
    }

    private val _state = MutableStateFlow(load())

    /** Changes on every [record], so the dashboard redraws its "last ran" lines. */
    val state: StateFlow<Snapshot> = _state.asStateFlow()

    fun last(entry: Entry): Long? = _state.value[entry]

    /** Stamps [entry] with [at] (now by default). Non-positive times are ignored. */
    fun record(entry: Entry, at: Long = clock()) {
        if (at <= 0) return
        store.write(entry.key, at)
        _state.value = load()
    }

    private fun load(): Snapshot = Snapshot(
        notesImport = read(Entry.NOTES_IMPORT),
        notesBackup = read(Entry.NOTES_BACKUP),
        mediaBackup = read(Entry.MEDIA_BACKUP),
        mediaImport = read(Entry.MEDIA_IMPORT),
    )

    private fun read(entry: Entry): Long? = store.read(entry.key)?.takeIf { it > 0 }
}

/** The app's [VaultHistory], kept in SharedPreferences. */
@Singleton
class VaultHistoryStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    val history = VaultHistory(object : VaultHistory.Store {
        override fun read(key: String): Long? = if (prefs.contains(key)) prefs.getLong(key, 0L) else null
        override fun write(key: String, value: Long) { prefs.edit().putLong(key, value).apply() }
    })

    val state: StateFlow<VaultHistory.Snapshot> get() = history.state

    fun record(entry: VaultHistory.Entry) = history.record(entry)

    private companion object {
        const val PREFS_NAME = "vault_history"
    }
}
