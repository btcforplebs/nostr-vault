package com.nostrvault.service

import android.content.Context
import android.util.Log
import com.nostrvault.data.model.FollowingSnapshot
import com.nostrvault.data.model.FollowingSnapshotStore
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages snapshots of the user's following list (kind 3 contact list).
 * Auto-snapshots on contact list load, deduplicates against the most
 * recent snapshot, and auto-prunes to MAX_SNAPSHOTS.
 *
 * Port of FollowingBackupService.swift.
 */
@Singleton
class FollowingBackupService @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        private const val TAG = "FollowingBackup"
    }

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }

    private val _snapshots = MutableStateFlow<List<FollowingSnapshot>>(emptyList())
    val snapshots: StateFlow<List<FollowingSnapshot>> = _snapshots.asStateFlow()

    /** Whose file [snapshots] holds. Writes for another account reload first,
     *  so one account's list is never saved into another's file (iOS:
     *  loadedAccountKey). */
    private var loadedAccountKey: String? = null

    fun loadSnapshots(forAccountKey: String) {
        loadedAccountKey = forAccountKey
        _snapshots.value = snapshotsFor(forAccountKey)
    }

    /** [forAccountKey]'s saved snapshots, read from its file without touching [snapshots]. */
    fun snapshotsFor(forAccountKey: String): List<FollowingSnapshot> {
        val file = snapshotFile(forAccountKey)
        if (!file.exists()) return emptyList()
        return try {
            json.decodeFromString<FollowingSnapshotStore>(file.readText()).snapshots
        } catch (e: Exception) {
            Log.w(TAG, "Failed to load snapshots: ${e.message}")
            emptyList()
        }
    }

    /**
     * Create a snapshot if the current contact list differs from the most recent snapshot.
     * Call this after the contact list (kind 3) loads from the relay.
     */
    fun maybeCreateSnapshot(
        pubkeys: List<String>,
        pTags: List<List<String>>,
        contactListContent: String,
        contactListCreatedAt: Long? = null,
        forAccountKey: String,
    ) {
        if (pubkeys.isEmpty()) return
        if (loadedAccountKey != forAccountKey) loadSnapshots(forAccountKey)

        val currentSet = pubkeys.toSet()
        val latest = _snapshots.value.firstOrNull()

        // Skip if identical to most recent snapshot — but adopt a newer created_at
        // so the local-edit guard reflects the latest publish.
        if (latest != null && latest.pubkeys.toSet() == currentSet) {
            if (contactListCreatedAt != null && contactListCreatedAt > (latest.contactListCreatedAt ?: 0L)) {
                val updated = _snapshots.value.toMutableList()
                updated[0] = latest.copy(contactListCreatedAt = contactListCreatedAt)
                _snapshots.value = updated
                saveSnapshots(forAccountKey, updated)
            }
            return
        }

        val snapshot = FollowingSnapshot(
            id = UUID.randomUUID().toString(),
            capturedAt = System.currentTimeMillis(),
            pubkeys = pubkeys,
            pTags = pTags,
            contactListContent = contactListContent,
            contactListCreatedAt = contactListCreatedAt,
        )

        val updated = (listOf(snapshot) + _snapshots.value)
            .take(FollowingSnapshotStore.MAX_SNAPSHOTS)
        _snapshots.value = updated
        saveSnapshots(forAccountKey, updated)
    }

    /**
     * The created_at of the most recent durable snapshot for an account, or 0 if
     * none. Primes the contact-list overwrite guard so an older relay copy can't
     * clobber a newer local edit — even after the feed snapshot TTL.
     */
    fun latestContactListCreatedAt(forAccountKey: String): Long {
        loadSnapshots(forAccountKey)
        return _snapshots.value.firstOrNull()?.contactListCreatedAt ?: 0L
    }

    fun deleteSnapshot(id: String, forAccountKey: String) {
        if (loadedAccountKey != forAccountKey) loadSnapshots(forAccountKey)
        val updated = _snapshots.value.filter { it.id != id }
        _snapshots.value = updated
        saveSnapshots(forAccountKey, updated)
    }

    /** Pubkeys that were in the snapshot but are NOT in the current following list. */
    fun removedSince(snapshot: FollowingSnapshot, currentPubkeys: List<String>): List<String> {
        val currentSet = currentPubkeys.toSet()
        return snapshot.pubkeys.filter { it !in currentSet }
    }

    /** Pubkeys that are in the current following list but were NOT in the snapshot. */
    fun addedSince(snapshot: FollowingSnapshot, currentPubkeys: List<String>): List<String> {
        val snapshotSet = snapshot.pubkeys.toSet()
        return currentPubkeys.filter { it !in snapshotSet }
    }

    private fun saveSnapshots(forAccountKey: String, snapshots: List<FollowingSnapshot>) {
        try {
            val store = FollowingSnapshotStore(snapshots = snapshots)
            snapshotFile(forAccountKey).writeText(json.encodeToString(FollowingSnapshotStore.serializer(), store))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save snapshots: ${e.message}")
        }
    }

    private fun snapshotFile(accountKey: String): File {
        return File(context.filesDir, "following_snapshots_${accountKey}.json")
    }
}
